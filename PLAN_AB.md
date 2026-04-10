# PLAN_AB -- Screen Time Scheduler

## Preamble: How PLAN_A and PLAN_B Compare

### Actual differences

The plans share approximately 90% of their design surface -- same frameworks (FamilyControls / ManagedSettings / DeviceActivity), same development-entitlement path, same single-regime enforcement (no system Downtime hybrid), same custom AFMT flow, same QR bootstrap, same daily 00:01 anchor recovery. The genuine divergences:

| Axis | PLAN_A | PLAN_B |
|------|--------|--------|
| **Source of truth** | CloudKit (peer-to-peer; every device is a first-class writer) | Mac SQLite (`stsd` daemon is the canonical brain) |
| **Mac daemon role** | Optional convenience (two topologies: with/without parent Mac) | Required authoritative server |
| **Override/window resolution** | Each device resolves locally via `OverrideEngine.effectiveWindows()` | Mac pre-compiles 48h intent records; devices execute them |
| **Manager write path** | CloudKit only | Tailscale HTTPS to Mac (fast path), CloudKit fallback |
| **FamilyControls on Mac** | Daemon has no FC auth; Controller app holds it | `stsd` XPCs to a GUI helper (`STSHelper.app`) for FC |
| **Data model naming** | "Subject" (kind: self/managed) | "Profile" with role sets |
| **Network dependency** | None beyond iCloud | Tailscale for manager fast-path (enforcement is CK-only) |

### Which is better on which axis

- **Resilience**: A wins. No single point of failure; every device can enforce from its local CK cache indefinitely. B's 48h intent horizon is mitigation, not parity.
- **Simplicity**: A wins. One sync mechanism (CloudKit), one topology model, no Tailscale dependency, no XPC protocol to maintain.
- **Manager write latency**: B wins marginally. Tailscale HTTPS to a local Mac is faster than CloudKit round-trip. In practice the difference is <1s vs 1--5s for schedule edits -- not user-perceptible for an infrequent operation.
- **Offline child enforcement**: Tie. Both cache locally. B's 48h pre-compiled intents are slightly more explicit; A's local OverrideEngine achieves the same result from cached CK records.
- **Self-shielding model**: A wins. The Subject abstraction cleanly handles self vs. managed in one type hierarchy. B's "Profile" concept is functionally equivalent but less precisely named.

### Same plan or different?

These are the same plan with a different authority model bolted on top. The enforcement path, AFMT flow, bootstrap, failure modes, and module structure are nearly identical. The "Mac-as-authority" vs. "CloudKit-as-authority" choice is the only architectural fork.

### Decision: Hybrid, based on PLAN_A

CloudKit as source of truth (A's model) is simpler and more resilient. B's Mac-authority adds a single point of failure and an extra network dependency (Tailscale) for negligible latency benefit on infrequent operations. However, B contributes two ideas worth keeping:

1. **XPC to GUI helper for Mac FC auth** -- cleaner than A's implicit "Controller app holds it" hand-wave. The daemon should not touch FC, and the separation should be explicit.
2. **48h intent caching** -- each device can cache a pre-resolved 48h window of intents alongside its CK records, improving offline resilience.

Everything below is the merged plan.

---

## Context

Apple's FamilyControls / ManagedSettings / DeviceActivity frameworks (RESEARCH section 1) let a third-party app shield apps on a schedule on iOS 16+, iPadOS 16+, and macOS 13+. This project runs on the **development-entitlement path** (RESEARCH section 9): no distribution review, schema mutable forever in Development CloudKit, $99/yr plus one annual reinstall per device.

Enforcement targets: **one iPad on iPadOS 26** and **one iMac 2017 on macOS 13 Ventura**. The iMac runs only the child's user account. Parent controls run on the parent's iPhone, plus optionally a separate parent Mac.

**Single-regime enforcement**: all shielding is via ManagedSettings shields. Apple's built-in Downtime is not used. A custom AFMT flow replaces Apple's entirely.

## Subjects and Roles

Management and enforcement are **orthogonal roles**. A device can hold either, both, or neither.

- **Manager**: reads/writes the shared schedule via CloudKit. No FamilyControls entitlement needed.
- **Enforcer**: holds FamilyControls authorization, writes shields to its local ManagedSettingsStore via the DAM extension.

The unit of shielding is a **Subject** -- an entity whose apps are shielded by some schedule:

- `Subject(kind: .self)` -- adult self-managing. Devices hold `.individual` FC auth. AFMT short-circuits locally.
- `Subject(kind: .managed)` -- child. Devices hold `.child` FC auth. AFMT goes through CloudKit to parent devices.

| Device | Manager? | Enforcer auth | Subject kind |
|--------|----------|---------------|--------------|
| Parent iPhone | yes | optional `.individual` | optional `.self` |
| Parent Mac (if present) | yes | optional `.individual` (via GUI helper) | optional `.self` |
| Child iPad | no | `.child` | `.managed` |
| Child iMac | no | `.child` | `.managed` |

**Soft-lock semantics**: `.individual` auth can be revoked from Settings at any time with no passcode. Self-shielding is a focus tool, not a tamper-resistant parental control.

## Architecture

**One app, many roles.** There is no separate "management app" and "child app." One app serves both roles -- schedule management and enforcement target. What differs per device is *runtime configuration*: which FamilyControls authorization it holds (`.individual` or `.child`) and which roles are active (manager, enforcer, or both). This is not just a design preference; Apple requires the same bundle ID on the parent device (where `FamilyActivityPicker(.child)` selects apps) and the child device (where shields take effect). Separate apps with different bundle IDs would break token transfer.

The Xcode project has separate platform targets (iOS/iPadOS, macOS) sharing a common Swift core. The diagram annotations below describe each device's runtime role, not a distinct application.

The only separate process is the optional macOS LaunchAgent daemon, which handles convenience tasks (pruning, notifications) and uses XPC to the main app for any FC-gated operation.

```
Parent iPhone          Parent Mac (optional)        Child iPad       Child iMac
 App                    App                          App              App
 FC .individual         FC .individual (via XPC)     FC .child        FC .child
 [manager+enforcer]     [manager+opt enforcer]       [enforcer only]  [enforcer only]
       |                  |      |                      |                |
       |                  |   XPC to main app           |                |
       |                  |   (LaunchAgent daemon)      |                |
       |                  |                             |                |
       +---------- CloudKit Dev (private DB) ----------+----------------+
                   CKShare per child Apple ID
                   CKQuerySubscription pushes
```

All devices run the same app and are peers writing to CloudKit. The parent Mac, if present, also runs a LaunchAgent daemon for three convenience tasks (none are correctness-critical):

- **Midnight override pruning**: Overrides are append-only CK records with `expiresAt` timestamps. A deterministic midnight timer deletes expired overrides so the log doesn't grow unbounded. Without the daemon, each device's `OverrideEngine` silently skips expired overrides when consulted, but the CK records linger until a device lazily cleans them up.
- **Centralized business-rule validation**: The daemon re-validates schedule writes (non-overlapping windows, valid time ranges) as a second check after CloudKit sync. Every device already validates locally before writing, so this is belt-and-suspenders — it catches edge cases where two devices write conflicting changes that each passed local validation independently.
- **Mac-side AFMT notifications**: Action-bearing `UNNotification`s (Deny / +15m / +1h / Rest-of-day) for child extension requests, presented on the parent Mac. Without the daemon, the parent iPhone is the only AFMT notification surface.

The daemon is **not** the source of truth. CloudKit is.

### Two topologies

- **(a) Separate parent Mac present**: hosts the daemon LaunchAgent for the three convenience tasks above. The main app holds FC auth; the daemon reaches it via XPC if the parent wants self-shielding on that Mac.
- **(b) No parent Mac**: the parent iPhone is the sole parent device. No daemon, no XPC. Override pruning falls back to lazy per-device cleanup; validation is per-client only; AFMT notifications go only to the iPhone.

Both topologies use CloudKit for all transport. The choice is a deployment knob, not a code branch.

## Data Model

- **Subject**: `id`, `displayName`, `kind` (self | managed), `timezone`, `devices: [Device]`.
- **Schedule**: per-subject weekly template. `subjectId`, windows, `version`, `updatedAt`.
- **Window**: `id`, `weekdays`, `start`, `end`, `groupId: WindowGroupID`, `allowRequests`. Every window is a shield -- no mode enum.
- **Override**: append-only. `id`, `subjectId`, `deviceId?`, `kind`, `createdBy`, `createdAt`, `expiresAt`. Kinds: reject, extend(minutes), restOfDay, skipWindow, addBlock, disableAllForDay.
- **Device**: `id`, `subjectId`, `platform`, `osVersion`, `capabilities: Set<Capability>`.
- **TokenBundle**: per-device opaque token blobs keyed by `deviceId`, indexed by `WindowGroupID`. Tokens stay on the device that picked them.
- **ExtensionRequest**: `id`, `subjectId`, `deviceId`, `windowId`, `appTokenRef`, `createdAt`, `state` (pending | decided), `decisionRef?`.

**Conflict resolution**: Overrides are append-only (no conflicts). Schedules/Windows use CloudKit's server-stamped `modificationDate` for LWW and `CKRecordSavePolicy.ifServerRecordUnchanged` for CAS. Server-side timestamps eliminate client-clock-skew issues.

## Sync Strategy

- Parent iCloud private DB, custom zone `ScheduleZone`, `CKShare` to each child Apple ID.
- Development CloudKit environment permanently (RESEARCH section 9).
- Per-type `CKQuerySubscription` for silent pushes, filtered by `subjectId`.
- Each device runs an `actor SyncCoordinator` that materializes CK records into a local GRDB cache (App Group container).
- **48h intent cache**: after each sync, each device locally compiles the next 48h of resolved windows into an intent cache. If CloudKit is unreachable, enforcement continues from cached intents.
- **QR-bootstrap handshake** first (exchanges CK zone IDs + encryption keys), CKShare acceptance second. Avoids under-13 CKShare flakiness blocking first-run.

## Ask-For-More-Time (AFMT)

1. Child taps shielded app. `ShieldActionExtension` exposes "Ask for time."
2. Tap writes an `ExtensionRequest` to local outbox, then to CloudKit.
3. `CKQuerySubscription` silent push wakes parent devices.
4. Parent sees a `UNNotification` with actions: **Deny / +15m / +1h / Rest-of-day**.
5. Parent taps an action, writing an `Override` to CloudKit.
6. Child's DAM extension wakes via push, clears the shield for the granted duration.

**Self-subject short-circuit**: for `Subject(kind: .self)`, the `ShieldActionExtension` returns `.defer`, which opens the main app. The app detects the pending self-request and presents an approval sheet (**Deny / +15m / +1h / Rest-of-day**). The user approves themselves; the app writes the `Override` directly to the local GRDB cache (mirrored to CloudKit for multi-device sync). Steps 3--5 are skipped.

Round-trip target: <10s with both ends online. The parent Mac daemon (if present) is an always-online relay when the parent iPhone is asleep.

## Enforcement Per Device

One DAM schedule per window. `intervalDidStart` checks the weekday and applies the ManagedSettingsStore shield. `intervalDidEnd` clears the store. When an override is granted (via AFMT or pre-existing when the window starts), the shield is cleared and a non-repeating post-override schedule is registered from the override's expiry to the window's end, re-applying the shield for the remainder. The editor enforces non-overlapping windows (>=1s gap) to prevent boundary races.

**Recovery from missed callbacks**: idempotent re-registration triggered from:
- Daily 00:01--12:00 anchor schedule (wide window survives overnight-off devices)
- Every app launch
- Every DAM extension wake
- Every CloudKit silent-push wake
- (macOS) Wake-from-sleep ping via LaunchAgent

The handler diffs desired vs. current registration and no-ops when they match.

### Platform-specific notes

- **iPadOS 26 (child iPad)**: full modern API surface. Primary enforcement target.
- **macOS 13 Ventura (child iMac)**: first-generation Mac APIs. Known parity gaps handled by `CapabilityMatrix` (disables unsupported shield types in the editor). Fallback: the app polls CloudKit every 60s while a shield is active. Wake-from-sleep LaunchAgent pings DAM. Treat gaps as permanent (hardware cannot run macOS 14+).
- **Parent Mac (optional)**: LaunchAgent daemon for convenience (pruning, validation, notifications). FC-gated operations go via XPC to the main app, which holds `.individual` auth. Daemon responsibilities are not correctness-critical.
- **Parent iPhone**: regular CloudKit client. Optional self-target via `.individual` FC auth. The editor rejects adding the app's own bundle ID to any token group (prevents self-lockout).

## Module Layout

```
ScreenTimeScheduler/
  App/              iOSApp, iPadApp, macOSApp, AppDelegate+Push
  Core/
    Models/         Schedule, Window, Override, Subject, Device, TokenBundle
    Persistence/    LocalStore (GRDB), AppGroupPaths, IntentCache
    Sync/           CloudKitSchema, SyncCoordinator (actor), SubscriptionManager
    Scheduling/     ScheduleCompiler, OverrideEngine, CapabilityMatrix
    Enforcement/    ShieldController, TokenResolver
    Requests/       ExtensionRequestOutbox, NotificationActionHandler
  Extensions/
    DeviceActivityMonitorExtension/
    ShieldConfigurationExtension/
    ShieldActionExtension/
  UI/
    Onboarding/     FamilyControlsAuth, QRPairingView, DeviceCapabilityCheck
    Schedules/      ScheduleEditorView, WindowEditorView, FamilyActivityPickerHost
    Overrides/      TodayOverrideView
    Family/         SubjectListView, DeviceListView
  macOSDaemon/
    SchedulerDaemon (LaunchAgent), FCHelperXPC (XPC to main app)
  Shared/
    Logging
```

## Failure Modes

1. **CK propagation lag**: silent push + 60s foreground polling fallback while a request is pending.
2. **DAM missed callback**: idempotent re-registration on multiple triggers (see Recovery above).
3. **Token drift after OS upgrade**: `TokenResolver` verifies tokens at launch, surfaces re-pick UI per group.
4. **All parent devices offline**: children enforce from local cache. Edits queue and flush on reconnect.
5. **Child uninstalls app**: blocked by `.child` FC auth (requires guardian passcode). On macOS, admin credentials required.
6. **iCloud account change**: CK zone resets; re-pair via QR.
7. **macOS API gaps**: `CapabilityMatrix` disables unsupported shield types per device.
8. **System Downtime overlap**: orthogonal stores, no arbitration. Onboarding asks user to disable system Downtime on enforced devices.
9. **Adjacent-window boundary race**: editor enforces >=1s gaps.
10. **ShieldAction killed mid-write**: local outbox first; main app flushes on next launch.
11. **Mac daemon down**: pruning/validation/notifications degrade gracefully. Not correctness-critical.
12. **App shielded by itself**: editor rejects the app's own bundle ID; ShieldActionExtension hard-codes an exemption.
13. **Self-subject bypass**: `.individual` auth revocable from Settings at any time. Intentional -- focus tool, not parental control.

## Required Entitlements

- `com.apple.developer.family-controls` (development variant)
- `com.apple.developer.deviceactivity`
- `com.apple.developer.icloud-services` = CloudKit (Development)
- `aps-environment` = development
- App Group `group.com.example.sts`
- Background modes: remote-notification, processing
- Hardened runtime + LaunchAgent plist for Mac daemon

No distribution profile, no TestFlight, no App Store review. Annual per-device reinstall via Xcode (~10 min/device).

## Open Risks

1. **CKShare-to-child flakiness** -- mitigated by QR-first onboarding.
2. **macOS 13 Ventura API parity** -- iMac stuck on Ventura; treat gaps as permanent.
3. **macOS DAM reliability across sleep** -- wake-nudge LaunchAgent is a patch, not a fix.
4. **Token portability UX** -- FamilyActivityPicker per device per group, repeated after OS upgrades.
5. **Developer program lapse** -- $99/yr renewal; lapsing revokes provisioning profiles.
6. **iMac 2017 security EOL** -- household problem, not a plan defect.
7. **Apple API changes at WWDC** -- custom AFMT is the most framework-coupled piece. Dev path means no App Review risk, but API removal would require code changes.
