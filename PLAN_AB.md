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

The unit of shielding is a **Subject** -- an entity whose apps are shielded by some schedule. **A Subject maps 1:1 to an Apple ID.** All of a Subject's devices are signed in to that Apple ID; the `Subject.devices` array lists them.

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

- **Midnight override pruning**: `GrantOverride` and `BlockOverride` records are append-only and each carries an explicit `end` timestamp. A deterministic midnight timer deletes records whose `end` has passed so the log doesn't grow unbounded. Without the daemon, each device's `OverrideEngine` silently skips ended records when consulted, but the CK records linger until a device lazily cleans them up.
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
- **GrantOverride**: append-only. Clears or narrows shielding for the half-open interval `[start, end)`. `id`, `subjectId`, `groupId?: WindowGroupID`, `deviceId?`, `appToken?`, `start`, `end`, `originatingRequestId?`, `createdBy`, `createdAt`. `start` and `end` are absolute timestamps computed once at grant creation and never updated ("+15m tapped at 15:00" becomes `{start: 15:00, end: 15:15}`; "rest of day" becomes `{start: now, end: endOfDay(subject.timezone)}`; a pre-scheduled snow-day disable can set `start` in the future). Scoping: `groupId` nil is subject-wide (all groups); when `appToken` is non-nil the grant is **single-device app-scoped**, and `deviceId` must identify the owning device because `ApplicationToken` is opaque and only interpretable there. `originatingRequestId` links back to the `ExtensionRequest` for AFMT-sourced grants and is nil for parent-initiated grants.
- **BlockOverride**: append-only. Adds ad-hoc shielding. `id`, `subjectId`, `start`, `end`, `groupId: WindowGroupID`, `createdBy`, `createdAt`. Group-scoped, subject-wide (applies to every device of the subject).
- **Device**: `id`, `subjectId`, `platform`, `osVersion`, `capabilities: Set<Capability>`.
- **TokenBundle**: per-device opaque token blobs keyed by `deviceId`, indexed by `WindowGroupID`. Tokens stay on the device that picked them.
- **ExtensionRequest**: `id`, `subjectId`, `deviceId`, `windowId`, `appToken`, `createdAt`, `outcome` (`pending` | `denied` | `granted(GrantOverrideID)`), `decidedAt?`, `decidedBy?`. A denial is recorded on the request itself; a grant produces a `GrantOverride` and links it via `outcome`.

**Conflict resolution**: `GrantOverride` and `BlockOverride` are append-only (no conflicts); `ExtensionRequest.outcome` transitions pending -> decided exactly once, enforced by CAS. Schedules/Windows use CloudKit's server-stamped `modificationDate` for LWW and `CKRecordSavePolicy.ifServerRecordUnchanged` for CAS. Server-side timestamps eliminate client-clock-skew issues.

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
5. Parent taps an action:
   - **Deny**: CAS-update the `ExtensionRequest.outcome` from `pending` to `denied`. No `GrantOverride` is written.
   - **+15m / +1h / Rest-of-day**: write a `GrantOverride` with `[start, end)` computed at write time (`{now, now+15m}`, `{now, now+60m}`, or `{now, endOfDay(subject.timezone)}`) and CAS-update `ExtensionRequest.outcome` to `granted(grantOverrideId)`. The grant inherits the originating request's `deviceId`, `appToken`, and `groupId` (derived from the request's `windowId` → window), scoping it to the single device and single app the child tapped, and sets `originatingRequestId` to link back. Other devices of the same subject stay shielded — this is a deliberate deviation from Apple Screen Time, see Open Risks.
6. Child's DAM extension wakes via push. If granted, `OverrideEngine` includes the new record in its active set while `now` is in `[start, end)`: app-scoped grants subtract their `appToken` from the group's shield set; group-wide grants remove every token in the group. If denied, the shield stays as scheduled.

**Self-subject short-circuit**: for `Subject(kind: .self)`, the `ShieldActionExtension` returns `.defer`, which opens the main app. The app detects the pending self-request and presents an approval sheet (**Deny / +15m / +1h / Rest-of-day**). The user approves themselves; the app writes the decision directly to the local GRDB cache (mirrored to CloudKit for multi-device sync). Steps 3--5 are skipped.

Round-trip target: <10s with both ends online. The parent Mac daemon (if present) is an always-online relay when the parent iPhone is asleep.

## Enforcement Per Device

One DAM schedule per window. `intervalDidStart` checks the weekday and applies the ManagedSettingsStore shield. `intervalDidEnd` clears the store. When a `GrantOverride` is active (its `[start, end)` covers now and its scope matches the current window), the shield set is adjusted and a non-repeating post-override schedule is registered from the grant's `end` to the window's end, restoring the pre-override shield for the remainder. For **group-wide** grants the entire group's tokens are removed from the shield set; for **app-scoped** grants only the specific `appToken` is subtracted and re-added at the grant's `end`, leaving the rest of the group's apps shielded. The editor enforces non-overlapping windows (>=1s gap) to prevent boundary races.

**Recovery from missed callbacks**: idempotent re-registration triggered from:
- Daily 00:01--12:00 anchor schedule (wide window survives overnight-off devices)
- Every app launch
- Every DAM extension wake
- Every CloudKit silent-push wake
- (macOS) Wake-from-sleep ping via LaunchAgent

The handler diffs desired vs. current registration and no-ops when they match.

### Platform-specific notes

- **iPadOS 26 (child iPad)**: full modern API surface. Primary enforcement target.
- **macOS 13 Ventura (child iMac)**: first-generation Mac APIs. Known parity gaps handled by `CapabilityMatrix` (disables unsupported shield types in the editor). `ShieldAction` on macOS 13 is flakier than on iOS — it may fail to wake and process an AFMT override response, leaving the child shielded after the parent approved. Fallback: the app runs continuously as an `LSUIElement` agent (menu bar only, no dock icon) under a KeepAlive LaunchAgent, polling CloudKit every 60s while a shield is active so override responses aren't lost to extension misfires. Core shield-on/shield-off enforcement still works via DAM without the app running. Wake-from-sleep LaunchAgent pings DAM to re-register schedules after sleep. Treat gaps as permanent (hardware cannot run macOS 14+).
- **Parent Mac (optional)**: LaunchAgent daemon for convenience (pruning, validation, notifications). FC-gated operations go via XPC to the main app, which holds `.individual` auth. Daemon responsibilities are not correctness-critical.
- **Parent iPhone**: regular CloudKit client. Optional self-target via `.individual` FC auth. The editor rejects adding the app's own bundle ID to any token group (prevents self-lockout).

## Module Layout

```
ScreenTimeScheduler/
  App/              iOSApp, iPadApp, macOSApp, AppDelegate+Push
  Core/
    Models/         Schedule, Window, GrantOverride, BlockOverride, ExtensionRequest, Subject, Device, TokenBundle
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

1. **CK propagation lag during AFMT round trip**: CloudKit silent pushes typically land in 1--15s but can spike to minutes under server load. Two directions to cover:
   - **Request push (child → parent)**: child writes an `ExtensionRequest` to CloudKit; parent devices wake via `CKQuerySubscription` to show the action notification. If the push is delayed:
     - **Topology (a), parent Mac present**: the always-running daemon polls CloudKit on a deterministic timer and presents the notification on the Mac when it finds a pending request. This is the real fallback.
     - **Topology (b), parent iPhone only**: no automatic fallback -- iOS background execution is opportunistic, not on-demand, so nothing in the plan guarantees the app is foregrounded. The parent sees the notification whenever APNs eventually delivers the push. The **social fallback** is the mechanism: the child says "I sent you a request, did you get it?" and the parent opens the app. App launch always triggers `SyncCoordinator` to do a `CKFetchRecordZoneChangesOperation` against `ScheduleZone`, which pulls any pending `ExtensionRequest` records into the local cache. The requests view surfaces them with the same Deny / +15m / +1h / Rest-of-day actions the notification would have offered, producing an identical decision write. This is acceptable for a household tool; see Open Risks for when it isn't.
   - **Response push (parent → child)**: parent's decision writes a `GrantOverride` (or updates `ExtensionRequest.outcome` to `denied`) to CloudKit; child's DAM extension wakes via push to apply the decision. If the push is delayed, the fallback chain depends on the child device:
     - **Child iMac**: the app is open-at-login (see Bootstrap), so it continuously polls CloudKit every 60s while a shield is active and applies any override it finds.
     - **Child iPad**: the child has no reason to open the main app, so continuous polling isn't available. The fallback is the child's **natural retry**: a frustrated child taps the shielded app again, re-invoking `ShieldActionExtension`. Before writing a new `ExtensionRequest`, the extension does a targeted CloudKit fetch (and consults the local GRDB cache) for the current request's `outcome`. If it has been updated to `granted(grantOverrideId)`, the extension applies that `GrantOverride` directly against its own `ManagedSettingsStore` (same App Group, same authorization context as the main app and DAM extension) -- subtracting the grant's `appToken` from the shield set (the grant is already scoped to this device via its `deviceId`, and the token was picked on this device so it's interpretable here) -- then returns `.close` to dismiss the shield UI. The child drops straight back to the app they tapped, no main-app context switch. If the outcome is `denied`, the extension surfaces a denial message and returns `.close`. If still `pending` (or no prior request exists), the extension writes a fresh request (CloudKit dedupes by `id`, so the parent sees one request even if the child taps multiple times). The child's retry IS the recovery trigger -- no main-app interaction required.
     - **Catch-all (all devices)**: the daily 00:01 recovery anchor re-reconciles on the next morning wake, bounding worst-case drift at <24h.
2. **DAM missed callback**: idempotent re-registration on multiple triggers (see Recovery above).
3. **Token drift after OS upgrade**: `TokenResolver` verifies tokens against installed app inventory at launch. If tokens are stale, behavior depends on the subject kind:
   - **Managed child**: the app switches to a blanket category shield (all apps blocked except the enforcement app itself) for the affected window groups, erring on enforcement rather than failing open. The app surfaces a "tokens need refresh" status visible to the child but not actionable by them. The **parent** must re-pick tokens — either by running `FamilyActivityPicker(.child)` on the child's device directly (handed the device) or from their own device via Apple's guardian-context picker flow (iOS 16+, returns tokens valid on the child device). A silent push notifies parent devices that re-pick is needed.
   - **Self subject**: the app surfaces a re-pick UI directly; the user runs `FamilyActivityPicker` themselves.
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

## Bootstrap / First Run

Installation is via Xcode (USB or Wi-Fi pairing) to each device registered to the developer account. On first launch, the app walks through onboarding to establish its role, authorize FamilyControls, pair with the family, pick apps to shield, and register DAM schedules. Per-device steps:

### Parent iPhone

1. Install from Xcode.
2. App launches onboarding: request FamilyControls `.individual` authorization (single in-app prompt, user approves).
3. Sign in to iCloud (if not already). App creates `ScheduleZone` in CloudKit private DB.
4. Optionally configure a self-shielding Subject. If so, present `FamilyActivityPicker` to select app groups, then register DAM schedules.
5. Register for `CKQuerySubscription` silent pushes (AFMT requests from children).
6. App requests notification permission for AFMT action notifications.

### Parent Mac (optional)

1. Install app from Xcode. Install `SchedulerDaemon` LaunchAgent plist to `~/Library/LaunchAgents/`.
2. App launches onboarding: request FamilyControls `.individual` authorization.
3. LaunchAgent starts the daemon at login. Daemon connects to the app via XPC for any FC-gated operations.
4. Same CloudKit setup as parent iPhone (shares the same iCloud account and `ScheduleZone`).

### Child iPad (iPadOS 26)

1. Install from Xcode via USB/Wi-Fi.
2. App launches onboarding: request FamilyControls `.child` authorization. This triggers the standard parent-approval flow — a guardian must enter the Screen Time passcode on the child's device (or approve remotely).
3. QR-bootstrap handshake: parent scans a QR code displayed on the child device (or vice versa) to exchange CK zone IDs and encryption keys. Then accept `CKShare`.
4. Present `FamilyActivityPicker(.child)` on the child device to capture token sets per window group. Tokens are device-scoped and stay local.
5. App registers DAM schedules (one per window) and the daily 00:01--12:00 recovery anchor.
6. Register for `CKQuerySubscription` silent pushes (override responses from parents).
7. Onboarding prompts the user to disable Apple's built-in Screen Time Downtime on this device to avoid interference.

### Child iMac (macOS 13 Ventura)

1. Create a non-privileged standard macOS user account for the child. The child logs in to this account with their own Apple ID.
2. Install app from Xcode in the child's user session.
3. App launches onboarding: attempt to request FamilyControls `.child` authorization (matches the iPad, tamper-resistant). **Open question**: whether `.child` is actually available on macOS 13 for a Family Sharing child Apple ID — the framework is documented as available on macOS 13+ with "similar semantics" to iOS, but `.child` specifically has not been verified. If `.child` fails at runtime, fall back to `.individual` and flag the weaker guarantees (see Open Risks).
4. QR-bootstrap handshake and `CKShare` acceptance, same as child iPad.
5. Present `FamilyActivityPicker` to capture token sets.
6. App registers DAM schedules and the daily recovery anchor.
7. **Background operation**: the app is built with `LSUIElement = true` (no dock icon, no app switcher entry, no application menu). A small menu bar item is the only visible surface, used by the parent for token re-pick and status. The child has no affordance to quit the app through normal UI.
8. Install a LaunchAgent plist to `~/Library/LaunchAgents/` in the child's session with `RunAtLoad = true` and `KeepAlive = true`. This launches the app at login and automatically relaunches it if it exits. The same LaunchAgent also pings DAM on wake from sleep.

### Annual maintenance

Development provisioning profiles expire after 12 months. Rebuild and reinstall from Xcode on each device (~10 min/device). Set a calendar reminder. The app continues running after expiry until iOS/macOS revalidates the profile, but don't rely on the grace period.

## Open Risks

1. **CKShare-to-child flakiness** -- mitigated by QR-first onboarding.
2. **macOS 13 Ventura API parity** -- iMac stuck on Ventura; treat gaps as permanent.
3. **macOS DAM reliability across sleep** -- wake-nudge LaunchAgent is a patch, not a fix.
4. **Token portability UX** -- FamilyActivityPicker per device per group, repeated after OS upgrades. Managed child devices fall back to blanket category shields until a parent re-picks tokens (see Failure Modes #3). Category token stability across upgrades is unverified — if categories also invalidate, the blanket shield would need to use a hard-coded "all categories" set rather than stored tokens.
5. **Developer program lapse** -- $99/yr renewal; lapsing revokes provisioning profiles.
6. **iMac 2017 security EOL** -- household problem, not a plan defect.
7. **Apple API changes at WWDC** -- custom AFMT is the most framework-coupled piece. Dev path means no App Review risk, but API removal would require code changes.
8. **Topology (b) relies on a social fallback for delayed request pushes** -- if the parent runs iPhone-only and APNs delays a child's AFMT request push, the plan falls back to the child telling the parent out-of-band ("did you get my request?"), after which the parent opens the app and the startup sync picks up the pending request. Acceptable for a household tool where the parent and child are typically co-located or in contact. The mitigation for households where the social channel is unreliable (parent at work, child home alone) is to run topology (a) with a parent Mac daemon.
9. **FamilyControls `.child` availability on macOS 13** -- unverified. The framework is documented as available on macOS 13+ with "similar semantics" to iOS, but it is not confirmed that `.child` authorization specifically works on a Mac signed in as a Family Sharing child Apple ID. If it does, the child iMac gets the same tamper-resistant enforcement as the iPad. If it doesn't, the plan falls back to `.individual`, which the child can revoke from Settings at any time with no passcode -- a significant weakening of enforcement on the iMac. Needs to be verified empirically before building. If `.child` is unavailable, consider whether the iMac is a viable enforced child device at all under this plan.
10. **Cross-device app identity / single-device AFMT grants** -- `ApplicationToken` is opaque and device-scoped, and there is no public API to match "Instagram on the iPad" with "Instagram on the iMac". App-scoped AFMT grants are therefore **single-device by design**: a parent approving Instagram on the iPad leaves the iMac shielded. This is a deliberate deviation from Apple Screen Time, which propagates grants cross-device using internal (non-public) token→bundle-ID mappings. The workaround is out-of-band: the parent issues a second grant on the other device if needed, or defines groups such that a group-wide grant covers the intended apps. A label-based join (capture `localizedDisplayName` at pick time and match by name) was considered and rejected as too flimsy for an edge case.
11. **macOS 13 per-token unshield** -- unverified. App-scoped grants assume `ManagedSettingsStore.shield.applications` on macOS 13 supports subtracting a single token from the shield set atomically (and re-adding it at expiry). Untested on this platform. If broken, app-scoped grants on the child iMac would degrade to group-wide grants. Verify in `CapabilityMatrix` during first-week spike; if the capability is absent, the `OverrideEngine` on that device widens any app-scoped grant to its enclosing group.
