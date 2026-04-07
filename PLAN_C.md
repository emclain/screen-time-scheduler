# PLAN_C — Native Downtime via Configuration Profiles + Shortcuts Glue

## Context
Per RESEARCH.md, Apple offers no public API to toggle system Downtime, and any third-party `ManagedSettings` shield breaks Apple's native "request more time" approval flow. The only sanctioned way to mutate the *system* Screen Time configuration off-device is via an MDM `com.apple.screentime` / `Restrictions` payload delivered as a configuration profile to a supervised device. This plan therefore minimizes custom code: no FamilyControls entitlement, no `ApplicationToken`/`FamilyActivityPicker`, no DeviceActivityMonitor extension, no sibling child app. Instead, an always-on Mac rotates pre-built configuration profiles that *are* Apple's native Downtime, leaving the system UI (and Ask-For-More-Time) entirely intact.

## Architecture

```
        +--------------------------+
        |  Always-on Mac (brain)   |
        |                          |
        |  launchd timers          |
        |  profile-rotator daemon  |
        |  profile library (.mobileconfig)
        |  state: current window, override
        +-----------+--------------+
                    |
        signed profiles via:
        (a) Apple Configurator 2 over USB/Wi-Fi to supervised iPhone
        (b) `profiles` CLI on the Mac itself (local Downtime)
        (c) self-hosted MDM (NanoMDM / MicroMDM) over APNs
                    |
         +----------+-----------+----------------+
         |                      |                |
   Parent iPhone           Child iPhone        Mac (self)
   (supervised)            (supervised)        (profiles CLI)
   System Downtime         System Downtime     System Downtime
   driven by profile       driven by profile   driven by profile

         ^                      ^                ^
         |  Ask-For-More-Time remains Apple's    |
         |  native flow on every device          |

   Parent iPhone Shortcut --HTTPS--> Mac daemon (override request)
                                       |
                                       v
                                  swap profile
```

## Setup / Supervision Requirements (honest about friction)
- **Supervision is mandatory** for the iPhones. Two viable paths:
  1. **Apple Configurator 2** on the Mac: factory-erase each iPhone, enroll into supervision via USB. This wipes the device once and shows a "This iPhone is supervised by [Org]" banner in Settings forever after. No ongoing MDM server strictly required if profiles are pushed by USB/Wi-Fi sync, but practical rotation needs OTA delivery.
  2. **Apple Business Manager / Apple School Manager + MDM**: not realistic for a consumer family — requires a D-U-N-S number / institutional verification.
- **Ongoing profile delivery** for over-the-air rotation needs an MDM server. The cheapest credible options:
  - Self-host **MicroMDM** or **NanoMDM** on the Mac (free, requires APNs push cert via an Apple Developer account; the cert is the painful part — you need an MDM vendor cert which Apple does not freely issue to individuals). Realistic fallback: schedule profile installs via Configurator 2's "Blueprints" + Wi-Fi pairing, accepting that the iPhone must be on the home LAN.
  - Or pay for a small-business MDM with a family-friendly tier.
- **Mac itself** does not need supervision for its own Downtime — `sudo profiles install -path ...` works on the local Mac (System Settings will show the profile and the user must approve once).
- **Family Sharing**: still used for the human side (iCloud, app purchases, Ask-For-More-Time approvals route to the parent's Apple ID as today). Family Sharing is *not* the transport for our schedule changes — supervision/MDM is.
- Friction summary: one-time wipe + supervise of each iPhone, one-time MDM trust prompt, one APNs cert headache. After that, zero per-day user interaction.

## Schedule encoding as profile(s)
Apple's `com.apple.screentime` payload accepts a Downtime schedule as `DowntimeStartTime` / `DowntimeEndTime` (minutes since midnight) plus a per-weekday enable map. Critically, **only one Downtime window per day is expressible in a single payload**. We work around this by representing the user's schedule as a finite set of payload variants and rotating which one is currently installed:

- Build a **profile library** at config time. For a schedule with N daily windows (e.g. 09:00-12:00, 14:00-17:00, 21:00-07:00), generate N+1 profiles:
  - `window_1.mobileconfig` — Downtime active 09:00-12:00 today.
  - `window_2.mobileconfig` — Downtime active 14:00-17:00 today.
  - `window_3.mobileconfig` — Downtime active 21:00-07:00 today.
  - `idle.mobileconfig` — no Downtime (or a 00:00-00:01 no-op window).
- Each profile carries the same `PayloadIdentifier`, so installing a new one **replaces** the previous atomically. No stacking, no orphaned policies.
- Per-weekday variation is handled by generating weekday-specific variants (`window_1_mon.mobileconfig`, etc.) — the daemon picks the right family for today's weekday.
- Profiles are signed once with a self-signed cert that's been trusted on each device during supervision; the user never sees an "untrusted profile" prompt during rotation.

The profile library is generated by a small Python script (~200 LOC) from a single YAML schedule the user edits. No app, no UI.

## Override mechanism (one-day, auto-revert)
- Override is *itself* just another profile: `override_today.mobileconfig` with whatever relaxed schedule the user wants (commonly: empty Downtime = totally off, or a single short evening window).
- When an override is requested, the Mac daemon:
  1. Records `override_until = next local midnight` in its state file.
  2. Installs `override_today.mobileconfig` on each target device (replacing the current window profile by `PayloadIdentifier`).
  3. At local midnight, launchd fires; daemon notices `override_until` has passed and resumes normal rotation by installing the appropriate `window_*` profile.
- Because the override is expressed as a profile swap, it survives Mac reboots: state is on disk, and the worst case is a few minutes of stale enforcement at boot before the daemon catches up.
- Multiple-day overrides, vacation mode, etc. fall out of the same mechanism trivially (different expiry timestamp).

## Mac daemon design
- **Language**: Python or Swift CLI. ~300 LOC.
- **Components**:
  - `schedule.yaml` — single source of truth (windows per weekday, target devices, override defaults).
  - `profilegen.py` — renders `.mobileconfig` plists from schedule.yaml + signs with the supervision cert.
  - `rotator` daemon — long-lived launchd `KeepAlive` job. Wakes on a 1-minute timer, computes "what profile *should* be installed right now on each device given (current time, weekday, override state)", and if it differs from last-applied state, issues an install.
  - `transport` adapters:
    - `local`: `sudo profiles install -path …` for the Mac itself.
    - `mdm`: HTTPS POST to local NanoMDM `/v1/commands` with an `InstallProfile` command targeting the iPhone's UDID.
    - `configurator`: AppleScript bridge to `cfgutil` for the Wi-Fi-pairing fallback.
  - `api` — tiny HTTP server on `localhost` + Tailscale, exposing `POST /override`, `GET /status`, `POST /pause`. Auth via shared secret.
- **launchd plists**: one for the daemon, one calendar-fired job at `00:00` to clear expired overrides (belt-and-braces; the daemon already handles it).
- **Logging**: append-only JSON log per profile install for audit / debugging missed events.

## How the parent iPhone controls things without being authoritative
- The parent iPhone has **two Shortcuts**:
  1. *"Override today"* — `Get Contents of URL` → `https://mac.tailnet.ts.net:8443/override` with a JSON body. Shows a confirmation banner.
  2. *"Resume normal schedule"* — same endpoint, `cancel=true`.
- These Shortcuts are pure HTTP clients. If the parent iPhone is offline or off, **nothing breaks** because the Mac daemon is the authority. Schedules continue rotating; the existing override (if any) still expires at midnight.
- The child's iPhone has no Shortcut and no app — it just receives profiles like any supervised device.
- Optional: a Home Screen widget showing current Downtime state by polling `/status`.

## How Ask-For-More-Time is preserved (the headline)
This is the entire reason to take this approach. Because the **only** thing being installed on the device is a system Downtime configuration — Apple's own first-party feature, parameterized — every user-facing surface remains exactly what Apple ships:

- The lock-screen "Time Limit" sheet that says *"Ignore Limit / Remind Me in 15 Minutes / One More Minute"* still appears.
- The child's *"Ask For More Time"* button still routes through Family Sharing to the parent's Apple ID via APNs, regardless of whether the parent's iPhone is online at the moment of request — Apple queues it.
- Parent approval still happens in the Messages/Notification UI the family is already trained on. No new approval channel to build, no in-app notifications, no CloudKit round-trip.
- No third-party `ManagedSettingsStore` shield is ever written, so there is no second layer that could swallow the request. The shield the user sees *is* Apple's shield.
- Because we never invoke FamilyControls, we don't trip the "this app is monitoring your screen time" privacy banner, and we don't need the `com.apple.developer.family-controls` entitlement (which can take weeks of App Review).

This is impossible to replicate with a FamilyControls-based architecture: as soon as third-party shielding turns on, Apple's request-more-time UI no longer governs the lock.

## Failure modes
- **APNs / MDM down**: scheduled profile swap doesn't reach iPhone. Last-installed profile remains in force; if it was a window profile, the iPhone keeps enforcing that window. Daemon retries with exponential backoff and surfaces failures via `/status`. The Mac itself is unaffected because it uses the local `profiles` CLI.
- **Mac powered off**: rotation stops. Whatever profile was last installed remains until the Mac is back. If override was active and Mac dies before midnight, override persists past expiry — soft failure, user-visible.
- **iPhone off the network during a transition**: profile install queues at the MDM server; applies on next check-in. Brief drift.
- **User dismisses supervision profile**: defeat. Mitigation: supervision profiles are non-removable on supervised devices unless wiped. That is the trade-off the family signs up for.
- **Apple changes the Screen Time payload schema**: profile library regenerator must be updated. Low frequency historically.
- **DST / timezone**: profiles use local time minutes-since-midnight; the daemon recomputes daily, handling DST.
- **Daemon crash**: launchd `KeepAlive` restarts; on restart, daemon reconciles desired vs actual state and corrects.

## Open risks
1. **Supervision is the elephant in the room.** For a consumer family with no Apple Business Manager account, the realistic supervision path is a one-time wipe-and-Configurator-enroll per iPhone. Some family members will balk at the visible "Supervised by …" banner and the implication that the device is "managed". This is the single biggest adoption risk.
2. **MDM APNs vendor cert.** Apple doesn't freely issue MDM vendor certs to individuals. Without one, NanoMDM/MicroMDM cannot push commands over APNs, and the only OTA path is Configurator-over-Wi-Fi (which requires the iPhone to be on the LAN and previously paired). For a child who carries the iPhone away from home, this can mean the daily profile rotation only happens when they get home — schedules would lag. Honest assessment: this approach is strongest for households where the kids' iPhones are routinely on home Wi-Fi, weakest for teens out of the house all day.
3. **`com.apple.screentime` payload completeness.** Apple's published payload reference covers Downtime start/end and per-weekday enable, but some sub-options (always-allowed apps, communication limits) have moved between iOS versions. The library must be re-validated against the target iOS major version.
4. **macOS Screen Time lag.** RESEARCH.md flags that macOS Screen Time has historically lagged iOS in API completeness; profile-driven Downtime on the Mac may have edge cases. Acceptable because the user's primary blocking target is the iPhones.
5. **No fine-grained per-app picking** since we skip FamilyActivityPicker. The user gets exactly what Apple's Downtime gives: an allow-list of always-permitted apps configured once in Settings. If the user wants per-window app sets, this approach can't deliver it without re-introducing FamilyControls (and losing the headline).
6. **Profile signing key custody.** The supervision/signing key on the Mac is a high-value secret. Compromise = ability to install arbitrary profiles. Mitigate with FileVault + Keychain ACL; out of scope for v1.

## Why this beats a big native app for this user
- Zero App Store / entitlement friction (no FamilyControls, no review).
- Zero sibling-app-on-child-device requirement.
- Ask-For-More-Time is preserved by construction, not by careful engineering.
- Small, auditable codebase (~500 LOC across profilegen + daemon + Shortcuts).
- The always-on Mac is used for what it's good at (cron + state), and the iPhones do nothing custom — they just receive Apple-format profiles.

The price is supervision and an MDM cert. The user must decide whether that price is worth keeping Apple's native UX intact.
