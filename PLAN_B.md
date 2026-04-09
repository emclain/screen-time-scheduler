# PLAN_B — Mac-as-Authoritative-Server Architecture

## Context

Build a personal Screen Time enhancement for one Family Sharing group. The household has an always-on Mac desktop; the parent's iPhone is frequently offline. Child devices are a **macOS Ventura iMac** and an **iPadOS 26 iPad**. Parent/management Macs run Sequoia or Tahoe. See RESEARCH.md for hard constraints.

This plan uses **single-regime enforcement**: all shielding is via `ManagedSettings` shields applied by our app. Apple's built-in Downtime is not used at all — no hybrid, no split enforcement boundaries, no UI confusion from two overlapping systems. A custom request-more-time flow replaces Apple's AFMT entirely.

### Deployment path

All development happens on the **development code-signing path** (RESEARCH §9). A paid Apple Developer Program membership ($99/yr) is the only prerequisite. `FamilyControls`, `ManagedSettings`, `DeviceActivity`, `ShieldConfiguration`, and `ShieldActionExtension` all work in development builds. No App Store review, no distribution entitlement application, no TestFlight. Builds run indefinitely (profile renewal once per year per device). CloudKit Development environment is fully functional and permanent.

## Device roles

A device holds zero or more of two **orthogonal roles**:

| Role | Capabilities | Authorization |
|------|-------------|---------------|
| **Manager** | Edit schedules, view status, approve/deny time requests | None beyond iCloud sign-in |
| **Enforcer** | Apply shields, fire DeviceActivity callbacks, present shield UI | `FamilyControls` `.individual` (self) or `.child` (managed user) |

A single device may be both manager and enforcer. An adult who wants self-shielding runs the app with `.individual` authorization and manages their own schedule. The always-on Mac is typically manager + enforcer; the child iPad is enforcer-only; the parent iPhone is manager + enforcer.

## Architecture

```
              +---------------------------------------+
              |  Always-on Mac (parent iCloud acct)   |
              |                                       |
              |  LaunchAgent → stsd (scheduler)       |
              |    ├── SQLite (source of truth)        |
              |    ├── CloudKit writer                 |
              |    ├── HTTPS API (Tailscale iface)     |
              |    └── XPC → GUI helper                |
              |             └── FamilyControls .individual
              |                + ManagedSettings store  |
              +------------------+--------------------+
                                 |
              CloudKit private DB (dev environment)
              + CK subscription pushes
                                 |
          +----------------------+----------------------+
          |                      |                      |
     Parent iPhone          Child iPad             Child iMac
     Manager + Enforcer     Enforcer               Enforcer
     (.individual)          (.child)               (.individual,
                                                    non-priv user)
```

### Tailscale scope

Tailscale provides low-latency access to the Mac's HTTPS API for **manager UIs only** (controller app on parent iPhone, or any Mac running the management interface). DeviceActivityMonitor extensions and ShieldActionExtension cannot reliably use Tailscale (they run in constrained extension contexts with no control over network configuration). All enforcement-path communication uses CloudKit exclusively.

## Components

### 1. Mac scheduler daemon (`stsd`)

Swift CLI launched by a **LaunchAgent** (not LaunchDaemon — it runs in the logged-in user session at `~/Library/LaunchAgents/com.local.stsd.plist`, `KeepAlive=true`, `RunAtLoad=true`).

Owns the canonical schedule and override database (SQLite at `~/Library/Application Support/stsd/state.sqlite`).

Responsibilities:
- Compile the human schedule into per-day **intent records**: `{deviceId, windowId, startUTC, endUTC, mode}` where `mode` is `shield(tokenSetId)` or `off`.
- Compute and apply override expiry (one-day override = intent with TTL pruned at next local midnight in the user's timezone).
- Publish intents to CloudKit (private DB, custom zone `ScheduleZone`) and per-child zones.
- Run a local HTTPS service on the Tailscale interface for low-latency manager reads/writes.
- Emit health heartbeats and structured logs to `~/Library/Logs/stsd/`.

**FamilyControls auth**: `stsd` itself is a CLI process and **cannot** hold FamilyControls authorization (the framework requires a GUI process with an application bundle). `stsd` communicates via **XPC** with a lightweight GUI helper app (`STSHelper.app`) that holds `.individual` authorization and owns the Mac's `ManagedSettingsStore`. The helper is a login item (launches at login, stays resident, no dock icon). `stsd` sends intent diffs over XPC; the helper applies them.

#### Ventura vs. Sequoia/Tahoe considerations for the always-on Mac

If the always-on Mac runs **macOS Ventura (13)**: FamilyControls, ManagedSettings, and DeviceActivity APIs are available (introduced in macOS 13) but are first-generation on Mac. Known quirks: DeviceActivityMonitor reliability is lower than on iOS; ShieldConfiguration rendering may differ. The 00:01 daily anchor (see §Reliability) compensates for missed callbacks. `stsd` itself uses no Screen Time APIs directly, so it runs identically on any macOS version.

If the always-on Mac runs **Sequoia (15) or Tahoe (16)**: two additional years of bug fixes in the Screen Time frameworks; DeviceActivityMonitor is more reliable; no known quirks. Preferred if available.

### 2. Manager app (multiplatform SwiftUI)

iOS + macOS app. UI for editing windows, toggling overrides, viewing device status, approving time requests. Stateless with respect to scheduling logic.

Writes: POST to Mac HTTPS endpoint via Tailscale first; if unreachable, write a `PendingCommand` CKRecord for `stsd` to ingest.

When the device is also an enforcer (e.g., parent iPhone), the same app binary includes the enforcement extensions (DeviceActivityMonitor, ShieldConfiguration, ShieldActionExtension) and holds FamilyControls `.individual` authorization.

### 3. Enforcer extensions (on every enforced device)

Bundled as extensions of the manager app binary:

- **DeviceActivityMonitor**: on `intervalDidStart`/`intervalDidEnd`, reads cached intents and writes the appropriate `ManagedSettingsStore` entries. Caches intents locally for offline operation.
- **ShieldConfiguration**: renders the block screen with a "Request More Time" button.
- **ShieldActionExtension**: handles the "Request More Time" tap (see §AFMT below).

On child devices the app runs in `.child` FamilyControls authorization mode, approved once via the parent's Screen Time passcode.

### 4. macOS child enforcement (iMac Ventura)

The child session runs under a **non-privileged standard macOS user account**. The enforcement app + extensions run in that user's session. The app holds FamilyControls `.individual` authorization (not `.child` — `.child` is for iOS/iPadOS where a parent Apple ID manages a child Apple ID; on macOS, the non-privileged user's own Apple ID signs in and the app shields that user's session with `.individual`).

The non-privileged account cannot modify LaunchAgents in other users' directories, cannot disable the enforcement app's login item via System Settings (if parental controls on the macOS account restrict System Settings access), and cannot delete the app without admin credentials.

## Data model

```
Profile(id, label, appleId, roles: Set<manager|enforcer>)
Device(id, profileId, platform: mac|iPad|iPhone, roles, pushToken, lastSeenUTC)
Window(id, profileId, weekdayMask, startMinute, endMinute)
TokenSet(id, profileId, deviceId, payload)        -- encrypted, opaque, device-local
Override(id, profileId, kind: extend|disable, grantMinutes, expiresAtUTC)
Intent(id, profileId, deviceId, startUTC, endUTC, mode, version)
Heartbeat(deviceId, ts, schedVersion)
TimeRequest(id, deviceId, requestedOption, ts, status, resolvedByDeviceId)
```

`mode` is always `shield(tokenSetId)` or `off` — no `systemDowntime` variant. The Mac daemon emits intents for the next 48 h, versioned. Helpers cache and run offline for at least 48 h.

## Transport and sync

**Primary: CloudKit private database** (parent's iCloud, dev environment) with per-child zones. On child iPadOS devices, access is via `CKShare` accepted at install time. On the macOS child (non-privileged user with their own Apple ID), the app reads from a shared zone the parent's iCloud account publishes to.

**Key exchange for CKShare to child Apple ID**: at bootstrap the parent device generates a per-child symmetric key and displays it as a QR code. The child device scans it. This key encrypts sensitive fields (token set payloads, override details) within CKRecords. The QR exchange is a one-time operation; key rotation requires re-scanning. If `CKShare` acceptance fails for under-13 accounts, this same symmetric key enables a fallback: records are written to a shared custom zone readable by any authenticated device that knows the key, bypassing `CKShare` entirely.

**Secondary: Tailscale HTTPS** on the Mac — manager UI fast path only (see §Tailscale scope above).

**Pushes**: CloudKit `CKQuerySubscription` silent pushes wake enforcer extensions when intents or time-request responses change. This is the primary near-real-time channel.

Rejected: self-hosted backend, MDM, iMessage automation (see RESEARCH.md).

## Request More Time (custom AFMT)

Flow:

1. Child taps shielded app → `ShieldConfiguration` renders block screen with **"Request More Time"** button.
2. Child taps button → `ShieldActionExtension` fires, writes a `TimeRequest` CKRecord (`status=pending`) to the child's CloudKit zone.
3. `CKQuerySubscription` wakes the manager app (parent iPhone and/or Mac). A system notification appears: **"[Child] requests more time for [app/category]"** with action buttons.
4. Parent picks: **Deny** / **+15 min** / **+1 hour** / **Rest of day** (until local midnight).
5. On approval: manager app (or `stsd` on Mac) writes an `Override` record with `expiresAtUTC` computed from the grant, publishes updated intents, and sets `TimeRequest.status=approved`.
6. `CKQuerySubscription` wakes the child's DeviceActivityMonitor extension. It reads the new intent (mode=`off` for the override window), clears the relevant `ManagedSettingsStore` entries. Shield drops within seconds of CloudKit propagation.
7. On deny: `TimeRequest.status=denied`, child's shield UI updates to show "Request denied."
8. If parent is unreachable: request queues. `stsd` on the always-on Mac is the fallback approver surface — parent can approve from the Mac UI even if the iPhone is offline.

Latency: CK subscription pushes typically arrive in 1–15 seconds. The Tailscale path is not used here (extensions cannot rely on it).

## Reliability

### Daily 00:01 recovery anchor

Instead of a 5-minute APNs heartbeat (which hits CloudKit/APNs rate limits and is not reliable), each enforcer schedules a **DeviceActivitySchedule anchored at 00:01 local time daily**. When the `intervalDidStart` callback fires, the extension:
1. Fetches the latest intents from CloudKit (or reads local cache if offline).
2. Reconciles the `ManagedSettingsStore` against what should be active *right now*.
3. Re-registers DeviceActivitySchedules for all remaining windows in the next 48 h.

This guarantees that even if every intra-day callback is missed, enforcement resets correctly once per day. Intra-day corrections arrive via CK subscription pushes (opportunistic, not polled).

### Other failure modes

- **Mac reboot**: launchd restarts `stsd`; SQLite is durable; on startup recomputes 48 h of intents and republishes.
- **Child uninstalls app**: blocked by FamilyControls `.child` authorization on iPadOS (requires Screen Time passcode). On macOS, the non-privileged account cannot delete the app without admin credentials.
- **Token set drift** (child installed a new app): "stale token set" warning in the manager UI.
- **CloudKit propagation lag**: for manager writes, Tailscale HTTPS is the fast path. For enforcement, CK subscription pushes are the only channel; the 00:01 anchor is the backstop.
- **CKShare to child Apple ID quirks**: QR-based symmetric key fallback (see §Transport).
- **DST / timezone**: intents stored UTC, override expiry computed against stored IANA tz, recomputed at each window boundary.
- **Clock skew**: helpers refuse intents with `version` older than the latest seen.

## How the Mac handles device-scoped ApplicationTokens

The Mac cannot mint or hold tokens for other devices. Token capture happens on each child device during bootstrap via `FamilyActivityPicker`. Tokens are stored locally; an opaque `TokenSetId` + encrypted blob is uploaded to the device's CloudKit zone. The Mac references `TokenSetId`s by UUID in intent records — never dereferences tokens. Adding a new app to a token set requires the child device (parent runs the picker on it or the child does with approval).

## Bootstrap / install

1. **Apple Developer Program** ($99/yr). Enable FamilyControls capability in Xcode on the App ID. No entitlement application needed — development signing includes it automatically.
2. **Xcode targets**: `STSApp` (multiplatform SwiftUI: manager + enforcer), `STSHelper` (macOS GUI helper for XPC), `stsd` (macOS CLI), plus extension targets (DeviceActivityMonitor, ShieldConfiguration, ShieldActionExtension).
3. **Always-on Mac**: install `STSApp`, `STSHelper` (login item), `stsd` + LaunchAgent. Grant FamilyControls `.individual` to `STSHelper`. Configure Tailscale.
4. **Parent iPhone**: install `STSApp`, sign in to same iCloud, grant FamilyControls `.individual`.
5. **Child iPad (iPadOS 26)**: install `STSApp` via USB/Wi-Fi from Xcode. Parent enters Screen Time passcode for `.child` authorization. Accept `CKShare` (or scan QR for key exchange). Run `FamilyActivityPicker` to capture token sets.
6. **Child iMac (Ventura)**: create non-privileged user account. Install `STSApp` from Xcode in that user session. Grant FamilyControls `.individual`. Scan QR for key exchange. Run `FamilyActivityPicker`. Restrict System Settings access for the account via Parental Controls.
7. Define schedules/windows via the manager UI; verify via `stsd` logs and enforcer status.

Annual maintenance: rebuild and reinstall from Xcode when provisioning profiles approach 12-month expiry (~10 min per device).

## Open risks

1. **DeviceActivityMonitor reliability** across reboots and low-power mode is empirically imperfect; the 00:01 anchor mitigates but does not eliminate all gaps.
2. **macOS Ventura Screen Time API maturity**: first-generation on Mac, less battle-tested than iOS. If DeviceActivityMonitor proves unreliable on Ventura, `stsd` can write `ManagedSettingsStore` directly via XPC to the GUI helper on a timer — degraded but functional.
3. **CKShare to under-13 Apple IDs** has had quirks; QR-key fallback addresses this.
4. **Apple could change third-party shield rules** at any WWDC; the custom AFMT flow is the most framework-coupled piece. Development-path deployment means no App Review risk, but API removal would require code changes.
5. **Single Mac = single point of failure** for the scheduling brain; 48 h cached-intent horizon on every enforcer is partial mitigation.
6. **CloudKit subscription push latency** is typically 1–15 s but can spike to minutes under server load. Time-sensitive requests (AFMT) may feel sluggish in rare cases.
7. **$99/yr renewal**: lapsing revokes provisioning profiles. Calendar reminder.
