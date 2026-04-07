# PLAN_B — Mac-as-Authoritative-Server Architecture

## Context
Build a personal Screen Time enhancement covering both a parent and a child Apple ID in one Family Sharing group, controllable from iPhone and Mac, supporting multiple Downtime windows per day, one-day auto-reverting overrides, and preserving Apple's "request more time" notification flow. The household has an always-on Mac desktop; the parent's iPhone is frequently offline. RESEARCH.md establishes the hard constraints: ManagedSettings is device-local, ApplicationTokens are device-scoped, DeviceActivitySchedule is a single contiguous interval, there is no public API to toggle system Downtime, and Ask-For-More-Time only works against Apple's own system Downtime (not third-party shields).

This plan picks **Strategy B from RESEARCH §1** (drive system Downtime) wherever feasible to preserve Ask-For-More-Time, and falls back to third-party shielding only for windows the system schedule cannot express. The Mac is the authoritative scheduling brain and sync server; iOS/macOS apps are thin enforcement clients.

## Architecture diagram

```
                 +-------------------------------------+
                 |  Always-on Mac (parent iCloud acct) |
                 |                                     |
                 |  launchd  -->  scheduler daemon     |
                 |                  |                  |
                 |                  +-- SQLite (truth) |
                 |                  +-- CloudKit writer|
                 |                  +-- APNs pusher    |
                 |                  +-- HTTPS API      |
                 |                       (Tailscale)   |
                 |                                     |
                 |  FamilyControls .individual helper  |
                 |  (shields Mac apps locally)         |
                 +-----------+-------------------------+
                             |
              CloudKit private DB (parent iCloud)  +  APNs silent pushes
                             |
        +--------------------+---------------------+
        |                    |                     |
   Parent iPhone        Parent iPhone         Child iPhone/iPad
   "Controller" app     Helper extension      "Enforcer" sibling app
   (UI + thin client)   (DeviceActivity +     (FamilyControls .child,
                         ManagedSettings)      DeviceActivity, MS store,
                                               Ask-For-More-Time bridge)
```

## Components

### 1. Mac scheduler daemon (`stsd`)
- Swift command-line tool launched by a `LaunchAgent` (`~/Library/LaunchAgents/com.local.stsd.plist`, `KeepAlive=true`, `RunAtLoad=true`).
- Owns the canonical schedule and override database (SQLite at `~/Library/Application Support/stsd/state.sqlite`).
- Responsibilities:
  - Compile the human schedule into per-day "intent records": `{deviceId, windowId, startUTC, endUTC, mode}` where `mode ∈ {systemDowntime, thirdPartyShield, off}`.
  - Compute and apply override expiry (a one-day override is an intent record with a TTL row pruned at next local midnight in the user's timezone).
  - Publish intent records to CloudKit (private DB, custom zone `ScheduleZone`) and trigger silent APNs to wake helpers.
  - Run a local HTTPS service on `127.0.0.1` and on the Tailscale interface for low-latency LAN/VPN reads when CloudKit is slow.
  - Run its own FamilyControls `.individual` enforcement on the Mac.
  - Emit health heartbeats and structured logs to `~/Library/Logs/stsd/`.

### 2. iOS controller app + macOS controller UI
- Multiplatform SwiftUI app. UI for editing windows, toggling overrides, viewing status. **Stateless** with respect to scheduling logic.
- All writes are POSTs: first try the Mac's HTTPS endpoint over Tailscale; if unreachable, write a CKRecord into a `PendingCommands` zone for the daemon to ingest.
- Hosts a small FamilyControls `.individual` helper so the parent's iPhone is also an enforcement device, listening to CloudKit subscriptions / silent pushes for the parent profile's intent records.
- Includes a DeviceActivityMonitor extension that, on `intervalDidStart`, reads the latest cached intent for "now" and writes the appropriate `ManagedSettingsStore`. Cached intents survive offline.

### 3. Child-device helper (sibling app on each child device)
- Same binary as the controller, launched in `.child` FamilyControls authorization mode; approved once via Apple's parent-passcode flow.
- Subscribes to its own CloudKit zone (`ChildZone-<childId>`) in the parent's CloudKit container — accessed via `CKShare` accepted at install time.
- DeviceActivityMonitor extension applies ManagedSettings locally based on intent records.
- Holds the child-device-scoped ApplicationTokens.
- Implements the Ask-For-More-Time bridge UI.

## Data model (SQLite on Mac, mirrored as CloudKit records)

```
Profile(id, label, ownerAppleId, kind: parent|child)
Window(id, profileId, weekdayMask, startMinute, endMinute, mode)
   mode: systemDowntime | thirdPartyShield(tokenSetId) | off
TokenSet(id, profileId, deviceId, payload)   // encrypted, opaque
Override(id, profileId, kind: skipNext|extendBy|disableUntil, expiresAtUTC)
Intent(id, profileId, deviceId, startUTC, endUTC, mode, version)
Device(id, profileId, kind: iPhone|iPad|Mac, pushToken, lastSeenUTC)
Heartbeat(deviceId, ts, schedVersion)
AskForMoreTimeRequest(id, deviceId, requestedMin, ts, status)
```

The Mac daemon emits `Intent` rows for the next 48h, versioned. Helpers cache the latest version and can run offline against the cache for at least 48h.

## Transport / sync choice and justification

**Primary: CloudKit private database (parent's iCloud) with `CKShare` granting child Apple ID read access to that child's zone.**
- Free, no server to operate.
- Built-in silent push subscriptions wake DeviceActivityMonitor extensions.
- Survives parent iPhone being offline because the Mac is a first-class CloudKit writer.
- Records are end-to-end via iCloud; no third-party trust.
- Family Sharing identity already exists.

**Secondary: Tailscale-exposed HTTPS endpoint on the Mac.**
- LAN/VPN path lets the controller app push an override and see it reflected within ~1s rather than waiting on CloudKit propagation.
- Local fallback when CloudKit is degraded.

**Tertiary: APNs silent push from the daemon by mutating a "ping" record** to nudge stale helpers (piggybacks on CloudKit subscriptions, no separate APNs cert).

Rejected: self-hosted backend (operational burden), MDM/Apple Configurator (RESEARCH §3 — too heavy for one family), iMessage automation (fragile).

## How the Mac drives child devices despite device-scoped ApplicationTokens

Central wrinkle. The Mac cannot mint or hold tokens that mean anything on the child's iPhone. Plan:

1. **Token capture happens on the child device, once.** During bootstrap the child-helper presents `FamilyActivityPicker` (or the parent presents it on the child's device, gated by Screen Time passcode). The selected tokens are stored locally on the child device and an opaque `TokenSetId` (UUID) plus encrypted blob is uploaded to the child's CloudKit zone.
2. **The Mac never dereferences tokens.** It only references `TokenSetId`s by id when composing `Intent` records. The child helper looks up the local token blob by id and writes it into its `ManagedSettingsStore`.
3. **Schedule changes are token-agnostic.** Adding/removing windows, overrides, weekday rules — all by id on the Mac, no picker round-trip.
4. **Adding a new app to a token set** is the only operation requiring physical access to the child device. The controller app surfaces this as "you need to update token set X on device Y".
5. **Mac enforcement of the parent profile** uses `.individual` tokens captured on the Mac itself.

## How Ask-For-More-Time is preserved

Ask-For-More-Time only fires against Apple's own system Downtime, which the public API cannot toggle. Strategy:

- **Default mode is `systemDowntime`**: the user configures the *primary* daily Downtime window in Apple's own Screen Time settings (one-time setup). For that window the third-party app does nothing, so Apple's Ask-For-More-Time UI is fully intact.
- **Additional windows** use `thirdPartyShield` mode. For these the third-party shield is active and the native AFMT bubble would not unlock it. We implement an **in-app Ask-For-More-Time bridge**:
  - The shield uses a custom `ShieldConfiguration` extension whose primary button is "Request more time".
  - Tapping it writes an `AskForMoreTimeRequest` record into CloudKit.
  - The parent controller app receives a CloudKit subscription push and surfaces a system notification with Approve / Deny actions.
  - On Approve, the daemon creates a short-lived `Override(kind=disableUntil, expiresAtUTC=now+grant)` and republishes intents; the child's helper clears the relevant `ManagedSettingsStore` keys within seconds.
  - The Mac daemon brokers approvals even when the parent iPhone is offline (parent can also approve from the Mac UI).

The user requirement is honored fully for the principal Downtime window and faithfully imitated elsewhere. **This tradeoff must be confirmed with the user.** If every window must use Apple's native flow, the only honest answer is that Apple does not expose this and the requirement cannot be fully met without MDM (see PLAN_C).

## Offline behavior

- **Mac daemon**: source of truth, expected online. If Mac is offline (rare), helpers run from cached intents (≥48h horizon) and any locally-stored override already accepted. New overrides cannot be created until the Mac returns or the controller app talks directly to the helper via CloudKit.
- **Parent iPhone**: thin client; offline means controller UI is read-only against its local cache. Its enforcement helper continues firing because intents and DeviceActivity schedules are locally registered.
- **Child device**: identical — runs from cached intents. AFMT requests generated offline are queued in a local outbox and flushed on reconnect.
- **Parent iPhone offline + Mac online** (the common case): fully covered.

## Failure modes and mitigations

1. **DeviceActivityMonitor missed callbacks**: 5-minute APNs heartbeat the helper uses to re-evaluate "what should be active now" and reconcile the `ManagedSettingsStore` even if a scheduled callback was dropped.
2. **CloudKit propagation lag**: Tailscale HTTPS path is the in-home fast lane.
3. **Mac reboot**: launchd restarts `stsd`; SQLite is durable; on startup the daemon recomputes the next 48h of intents and republishes.
4. **Child uninstalls helper**: blocked by FamilyControls `.child` authorization (requires Screen Time passcode).
5. **Token set drift** (child installed a new app not in the picker selection): "stale token set" warning in the controller app + periodic reminder on the child device.
6. **CKShare to child Apple ID issues**: fall back to a public CloudKit container scoped per-household with record-level encryption keys exchanged at bootstrap (QR code).
7. **Entitlement rejection**: document the need for paid enrollment and Family Controls entitlement request early.
8. **DST / timezone**: intents stored UTC, override expiry computed against the user's stored IANA tz, recomputed at each window boundary.
9. **Clock skew**: helpers refuse intents with `version` older than the latest seen and trust device-local time after sanity-check vs daemon heartbeat.

## Bootstrap / install process

1. Enroll in Apple Developer Program; request `com.apple.developer.family-controls` for the app and its extensions.
2. Three Xcode targets: `Controller` (iOS+macOS app), `EnforcementHelper` (DeviceActivityMonitor + ShieldConfiguration extensions), `stsd` (macOS CLI).
3. On the Mac: install Controller, install `stsd` + LaunchAgent (provisions SQLite + CloudKit schema), configure the *primary* Downtime window in Apple Screen Time (this preserves native AFMT), grant FamilyControls `.individual`.
4. On the parent iPhone: install Controller, sign in to same iCloud, accept CloudKit zone, grant FamilyControls `.individual`.
5. On the child device: install Controller in `.child` mode, parent enters Screen Time passcode, accept `CKShare`, run `FamilyActivityPicker` once to capture token sets, label them, upload `TokenSetId` metadata.
6. Define windows/overrides via the controller; verify via daemon log and helper applied state.
7. Tailscale: install on Mac and parent iPhone; pin daemon HTTPS endpoint to the tailnet.

## Open risks

1. Apple may tighten FamilyControls review; entitlement can take weeks.
2. `DeviceActivityMonitor` reliability across reboots and low-power mode is empirically imperfect; heartbeat mitigates but does not eliminate gaps.
3. CloudKit `CKShare` to a child Apple ID has had quirks for under-13 accounts; may need QR-bootstrap fallback.
4. Apple could change the rules around third-party shields and AFMT at any WWDC; the bridge UI is the most fragile piece.
5. macOS Screen Time API parity with iOS — if the Mac cannot run a DeviceActivityMonitor reliably, Mac-side enforcement degrades to "launchd cron + ManagedSettings writes from `stsd` directly".
6. Single Mac = single point of failure for the brain; partial mitigation is the 48h cached-intent horizon on every helper.
7. The "preserve Apple's request more time flow" requirement is only fully honored for the system-Downtime window; additional windows get a faithful imitation. **Confirm with user.**
