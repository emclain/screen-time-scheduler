# PLAN_A — Native Swift + CloudKit Screen Time Scheduler

## Context
Apple's FamilyControls / ManagedSettings / DeviceActivity (RESEARCH §1) let a third-party app shield apps on a schedule on iOS 16+, iPadOS 16+, and macOS 13+. Per RESEARCH §9 this household runs on the **paid-developer-program development entitlement** path: no distribution review, no App Review, schema mutable in Development CloudKit forever, $99/yr plus one annual reinstall per device. That eliminates the entitlement-delay and AFMT-imitation-rejection risks prior drafts carried.

Target child devices: **one iPad on iPadOS 26** (full modern API surface) and **one iMac 2017 on macOS 13 Ventura** (Screen Time APIs present, with known parity gaps — see Enforcement). The iMac runs **only the child's user account**; the parent never logs in there and never uses it as a management surface. Parent controls run on the parent's iPhone, plus optionally a separate parent Mac (e.g. a MacBook) that hosts the always-on `SchedulerDaemon`. If no separate parent Mac is present, the parent's iPhone is the canonical writer and there is no always-on Mac brain — see Topology.

The prior draft proposed a hybrid of Apple's system Downtime (for the dominant window) and third-party shields (for the rest), to preserve Apple's native "more time" UI on at least one window. The hybrid is **dropped**. It was a convention, not an integration: the app could not read back system Downtime, so drift was silent, and two enforcement regimes ran side-by-side with no arbitration (CRITIQUE_1/2/3 all hit this). With the user's relaxed AFMT requirement below, the hybrid's only justification disappears. The revised plan runs **one enforcement regime** — third-party ManagedSettings shields on every window — with an in-app request/approve flow.

## Ask-For-More-Time (simplified per the new requirement)
The child does **not** see a pixel-perfect reimplementation of Apple's sheet. The flow:

1. Child taps a shielded app → the `ShieldActionExtension` exposes an "Ask for time" action.
2. Tap writes `CDExtensionRequest` to a local outbox (extension may be killed mid-write), then to CloudKit.
3. `CKQuerySubscription` silent push wakes parent devices.
4. Parent sees a standard `UNNotification` with four `UNNotificationAction`s: **Reject / +15m / +1h / Rest-of-day** (where rest-of-day = next local midnight in the **child's** timezone).
5. Parent taps an action → device writes a `CDOverride(kind, expiresAt)` to CloudKit.
6. Child's DAM extension wakes via push, clears the `ManagedSettingsStore` shield for the granted duration via a one-shot tail `DeviceActivitySchedule`, or holds it on reject.

Round-trip target: <10s with both ends online. In topology (a) — separate parent Mac present — the Mac daemon is the always-online fallback when the parent iPhone is asleep, and surfaces the same action notification in the parent's macOS session. In topology (b) the iPhone is the only approval surface, so latency is bounded by iPhone wake-from-push.

## Architecture diagram

```mermaid
flowchart LR
  subgraph Parent_Mac[Parent Mac always-on - optional, topology a]
    PUIm[SwiftUI Controller App]
    Daemon[SchedulerDaemon LaunchAgent]
    LSm[(LocalStore GRDB)]
  end
  subgraph Parent_iPhone
    PUIp[SwiftUI App]
    DAMp[DAM Ext]
  end
  subgraph Child_iPad[Child iPad iPadOS 26]
    CUIi[Sibling App .child]
    DAMi[DAM Ext]
    SAEi[ShieldAction Ext]
    MSi[ManagedSettingsStore]
  end
  subgraph Child_Mac[Child iMac Ventura]
    CUIm[Sibling App .child]
    DAMm[DAM Ext]
    SAEm[ShieldAction Ext]
    MSm[ManagedSettingsStore]
  end
  CK[(CloudKit Dev + CKShare)]
  APNs[(APNs)]
  PUIm <--> CK
  Daemon <--> CK
  PUIp <--> CK
  CUIi <--> CK
  CUIm <--> CK
  CK -- silent push --> APNs
  APNs --> DAMp
  APNs --> DAMi
  APNs --> DAMm
  DAMi --> MSi
  DAMm --> MSm
  SAEi -- request --> CK
  SAEm -- request --> CK
  CK -- decision --> DAMi
  CK -- decision --> DAMm
```

## Topology
FamilyControls / ManagedSettings / DeviceActivity on macOS are scoped per user account (each macOS user has their own iCloud, their own ManagedSettings store, their own DAM extension instance). The iMac therefore hosts **only the child's user session**, authorized to the child's iCloud in the family-sharing group, enforcing on that account. The parent does not have a session on the iMac — there is no auto-login dance, no fast-user-switch helper, no concurrent two-session memory pressure on a 2017 box, and no "parent must never log out" gesture restriction.

Two supported parent-side topologies:

- **(a) Separate parent Mac present** (e.g. a MacBook): hosts the `SchedulerDaemon` LaunchAgent in the parent admin user session. That Mac is the canonical writer and the always-on relay. The parent's iPhone is the secondary device. This is the configuration the Architecture diagram draws.
- **(b) No parent Mac, iPhone-only**: the parent's iPhone is the canonical writer. There is no always-on daemon. Schedule edits serialize through the single writer (no LWW clock-skew exposure because there is only one writer). Override pruning is opportunistic — whichever device launches near or after midnight sweeps expired overrides; the child devices also prune their own caches lazily on the next `OverrideEngine` consultation. APNs delivery to the iPhone is direct from CloudKit; no Mac relay is needed because there is no second device the request might fail to reach.

Both topologies use CloudKit + CKShare for transport between the parent's iCloud and the child's iCloud. The choice between (a) and (b) is a deployment knob, not a code branch — the iPhone app and the (optional) Mac daemon share the same SyncCoordinator and CanonicalWriter logic, and a per-installation flag elects which is the active canonical writer. If a Mac daemon is present and heart-beating it wins; otherwise the iPhone takes the role.

## Data model
- **Schedule**: per-child weekly template. `Window`s, `version`, `updatedAt`.
- **Window**: `id`, `weekdays`, `start`, `end`, `groupId: WindowGroupID`, `allowRequests`. No enforcement enum — every window is a shield.
- **Override**: append-only. `id`, `childId`, `deviceId?`, `kind`, `createdBy`, `createdAt`, `expiresAt`. `kind ∈ { reject, extend(minutes), restOfDay, skipWindow(id), addBlock(start,end), disableAllForDay }`.
- **Child**: `id`, `displayName`, `timezone`, `devices: [Device]`.
- **Device**: `id`, `platform ∈ { iPadOS, macOS, iOS }`, `osVersion`, `capabilities: Set<Capability>`.
- **TokenBundle**: per-device opaque token blobs keyed by `deviceId`, indexed by stable `WindowGroupID`. Tokens stay on the device that picked them; other devices see only the group reference.
- **CDExtensionRequest**: `id`, `deviceId`, `windowId`, `appTokenRef`, `createdAt`, `state ∈ { pending, decided }`, `decisionRef?`.

**Conflict resolution**: Overrides are append-only (delete + insert, never edit). Schedule/Window use `updatedAt` LWW serialized through a single **canonical writer** — the Mac daemon if topology (a), the parent's iPhone if topology (b). With one writer there is no clock-skew exposure of the kind CRITIQUE_3 raised against peer LWW. Failover via heartbeat election (see Enforcement) covers daemon outages in topology (a).

## Sync strategy (CloudKit)
- Parent iCloud private DB, custom zone `ScheduleZone`, `CKShare` to each child Apple ID.
- Runs against **Development CloudKit** (RESEARCH §9). Schema is mutable forever; no "Deploy to Production" step ever.
- Records: `CDSchedule`, `CDWindow`, `CDOverride`, `CDChild`, `CDDevice`, `CDExtensionRequest`, `CDTokenBundleRef` (no actual tokens). Per-type `CKQuerySubscription` for silent pushes.
- Each device runs an `actor SyncCoordinator` that materializes CK records into a local GRDB cache in the App Group container and feeds the enforcement layer.
- Onboarding order: **QR-bootstrap handshake first** (exchanges CK zone identifiers + record-encryption keys over local transport), CKShare second. Known under-13 CKShare flakiness thus never blocks first-run.

## Enforcement per device
The prior draft registered seven schedules per window per device plus per-window anchors, multiplying the race surface and pushing against the undocumented DAM ceiling for any non-trivial plan. Revised: **one schedule per window**, with weekday and override resolution deferred into `intervalDidStart` via `OverrideEngine.effectiveWindows(for: now, device:)`.

- **iPadOS 26 (child iPad)**: `DeviceActivityCenter` registers one schedule per window. `intervalDidStart` checks `weekday ∈ window.weekdays` against the local cache, applies the `ManagedSettingsStore` shield, and schedules a one-shot tail for any active extend/restOfDay override. `intervalDidEnd` clears the store. A **single** 00:01 daily anchor re-registers monitors, recovering from missed callbacks. The editor enforces non-overlapping windows (≥1s gap) so adjacent `intervalDidEnd`/`intervalDidStart` pairs cannot race a shared store (CRITIQUE_3 §5).
- **macOS 13 Ventura (child iMac 2017)**: same multiplatform target, same extension code. **Known parity gaps**: some `ManagedSettings` keys are no-ops on macOS 13; the `Capability` matrix on each `Device` record disables unsupported shield types in the editor for that device. `ShieldAction` on macOS is functional on 13+ but flakier — degraded fallback: the sibling app polls CloudKit every 60s while a shield is active so requests aren't lost to extension misfires. A lightweight LaunchAgent pings the DAM extension on wake from sleep, since macOS historically drops DAM callbacks across sleep cycles. The iMac is stuck on Ventura (hardware can't run 14+); whatever Apple has fixed since is unavailable here, so treat parity gaps as permanent.
- **Parent Mac, if present** (topology (a)): hosts the `SchedulerDaemon` as a **LaunchAgent** in the parent admin user session (NOT LaunchDaemon — FamilyControls auth requires a user-app context, and a LaunchDaemon at the loginwindow has no Mach bootstrap, no UNNotification access, and no FC). The daemon never holds FC auth itself; FC-gated operations are XPC-bounced to the Controller app. Responsibilities: canonical schedule writer, midnight override pruning, presenter of action-bearing `UNNotification`s for the parent on that Mac.
- **Parent iPhone**: same multiplatform app. In topology (a) it receives and can act on extension requests as a secondary surface; in topology (b) it is the **only** parent surface and is itself the canonical writer. **Canonical-writer election**: the active writer publishes a heartbeat record every 60s; if a 5-minute gap is observed, any other parent device may assume the role and the original picks up again on its next heartbeat. With one parent device this is a no-op; with two it provides clean failover.

## Module layout
```
ScreenTimeScheduler/
  App/
    iOSApp.swift, iPadApp.swift, macOSApp.swift, AppDelegate+Push.swift
  Core/
    Models/         Schedule, Window, Override, Child, Device, TokenBundle
    Persistence/    LocalStore (GRDB), AppGroupPaths
    Sync/           CloudKitSchema, SyncCoordinator, SubscriptionManager, CanonicalWriter
    Scheduling/     ScheduleCompiler, OverrideEngine, CapabilityMatrix
    Enforcement/    ShieldController, TokenResolver
    Requests/       ExtensionRequestOutbox, NotificationActionHandler
  Extensions/
    DeviceActivityMonitorExtension/
    ShieldConfigurationExtension/
    ShieldActionExtension/
  UI/
    Onboarding/   FamilyControlsAuth, QRPairingView, DeviceCapabilityCheck
    Schedules/    ScheduleEditorView, WindowEditorView, FamilyActivityPickerHost
    Overrides/    TodayOverrideView
    Family/       ChildListView, DeviceListView
  macOSDaemon/
    SchedulerDaemon.swift (LaunchAgent), FCHelperXPC (→ Controller app)
  Shared/
    Logging.swift
```

### Key types
- `struct Window { let id: UUID; var weekdays: Weekdays; var start: TimeOfDay; var end: TimeOfDay; var groupId: WindowGroupID; var allowRequests: Bool }`
- `enum OverrideKind { case reject; case extend(Int); case restOfDay; case skipWindow(UUID); case addBlock(TimeOfDay, TimeOfDay); case disableAllForDay }`
- `struct Device { let id: UUID; let platform: Platform; let osVersion: String; var capabilities: Set<Capability> }`
- `actor SyncCoordinator { func start(); func upsert<T: CKSyncable>(_ value: T); func handleRemoteNotification(_: [AnyHashable: Any]) }`
- `struct OverrideEngine { func effectiveWindows(for date: Date, device: Device) -> [ResolvedWindow] }`
- `final class ShieldController { func apply(_ resolved: ResolvedWindow); func clear(_ id: UUID) }`

## Failure modes
1. **CK propagation lag** → child stays shielded after approve. Silent push + 60s foreground polling fallback while a request is pending; daemon nudges via high-priority `CKModifyRecordsOperation`.
2. **DAM missed callback** → shield never applies. Single 00:01 daily anchor re-registers monitors; macOS LaunchAgent pings DAM on wake.
3. **Token drift after iOS upgrade** → tokens invalidate. `TokenResolver` verifies tokens against installed inventory at launch and surfaces re-pick UI per group. Pain on the dev-entitlement path is low: Xcode is on-hand.
4. **All parent devices offline** → no canonical writer; children enforce from local cache. New edits queue on the issuing device and flush on reconnect.
5. **Child uninstalls app** → blocked by FamilyControls `.child` (guardian passcode required).
6. **iCloud account change** on a device → CK zone resets; re-pair via QR.
7. **macOS API gaps** → `CapabilityMatrix` disables shield types the device can't enforce; editor greys them out per-device.
8. **User's own system Downtime overlapping ours** → orthogonal stores that don't arbitrate. Onboarding asks the user to disable system Downtime on enforced devices. No hidden mirror handshake.
9. **Adjacent-window boundary race** → editor enforces ≥1s gaps so two schedules never transition on the same store simultaneously.
10. **ShieldActionExtension killed mid-write** → extension writes to a local outbox first; main app flushes on next launch or DAM wake.
11. **Parent Mac daemon down** (topology (a) only) → no canonical writer for new edits. Mitigation: heartbeat election lets the iPhone temporarily assume the role; daemon resumes on next heartbeat. Children continue enforcing from local cache regardless.

## Required Apple entitlements (development path)
- `com.apple.developer.family-controls` — **development** variant, auto-enabled in Xcode for paid-program members with no application (RESEARCH §9). App + all 3 extensions on both platforms.
- `com.apple.developer.deviceactivity`
- `com.apple.developer.icloud-services` = CloudKit (Development environment)
- `aps-environment` = development
- App Group `group.com.example.sts`
- Background modes: remote-notification, processing
- Hardened runtime + LaunchAgent plist for the Mac daemon

No distribution profile, no TestFlight, no App Store review. Annual per-device reinstall via Xcode (~10 min/device).

## Open risks
1. **CKShare-to-child** flakiness. Mitigated by QR-first onboarding.
2. **macOS 13 Ventura API parity**. iMac 2017 can't run 14+, so anything Apple has fixed since Ventura is unavailable on that device. `CapabilityMatrix` + polling fallback is the extent of the mitigation.
3. **macOS DAM reliability across sleep**. Wake-nudge LaunchAgent is a patch, not a fix.
4. **Token portability UX**: `FamilyActivityPicker` per device per group, repeated after iOS upgrades invalidate tokens.
5. **Developer program lapse**: $99/yr renewal. If it lapses, provisioning profiles revoke on next device check-in.
6. **iMac 2017 security EOL**: when Apple drops Ventura security updates, the Mac child target becomes security-obsolete. Household problem, not a plan defect, but worth flagging.
7. **Topology (b) edit-latency bound**: with no Mac daemon, schedule edits are bounded by the parent iPhone's reachability. Enforcement is unaffected (children run from local cache), but a parent making an edit while their iPhone is offline will see it propagate only when the iPhone reconnects.
