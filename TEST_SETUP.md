# Hardware Test Setup — iMac 2017 / macOS 13 Ventura

This document tells you everything you need before running the hardware
verification tests (screen-72b, screen-8ky, screen-n4v, screen-uc3).

> ## ⚠️ Procedure below is partly obsolete — read this first
>
> The native macOS target **cannot** do any of this. `ManagedSettingsStore` and
> `AuthorizationCenter` are `@available(macOS, unavailable)` even in the Xcode 16
> SDK, and `CapabilityProbe`'s automated probes are stubs that return `.failed`
> (screen-htn). Mac Catalyst is the only path, and Catalyst cannot host the
> DeviceActivityMonitor, ShieldConfiguration, or ShieldAction extension points
> (screen-j49) — so there is no scheduled enforcement, no custom shield UI, and
> no shield-tap actions to test on a Mac.
>
> **What to actually run: the Catalyst build of the `ScreenTimeScheduler` scheme,
> driven from its own UI.** See "Gate tests" immediately below. The Step 1–5
> procedure further down still describes the old native-macOS/probe flow and is
> retained only for the iPad-side context.

## Gate tests (Catalyst, iMac 2017 / Ventura)

Run these in order. Each one gates the next; if one fails, the rest are moot and
the Mac enforcement path is dead as designed (see screen-8ia).

**Setup:** open Console.app, filter **Subsystem** = `net.emclain.ScreenScheduler`,
and leave it running. It is the only instrument you have — there is no Xcode on
Ventura, because Xcode 16 requires macOS 14.5+.

| # | Question | How | Pass looks like |
|---|----------|-----|-----------------|
| 0 | Does FamilyControls authorize at all on Ventura? | Launch the app, tap **Request Authorization** (`.individual`) | Status flips to "Authorized". Console shows `auth_granted`. Failure mode to expect: `FamilyControlsAgent` errors and status stuck at Not Determined |
| 1 | Does `FamilyActivityPicker` enumerate Mac apps? | Tap **Choose Apps to Block** | The picker lists real macOS apps. Note whether native apps (Safari, Finder) appear, or only Catalyst/iOS-style ones. **If it lists nothing usable, stop — there is nothing to shield** |
| 2 | Do shields actually block on a Mac? | Pick 2–3 apps, tap **Apply Shield to Selected** | The picked apps become unlaunchable and show Apple's default restricted screen. Console shows `shield_applied` with the token count |
| 3 | Per-token unshield (PLAN.md risk 11) | Tap **Unshield One App** | Exactly one app becomes usable again while the others stay blocked. Console shows `shield_token_removed remaining=N`. Failure: all unblock, or none do |
| 4 | Does `.child` authorization work? | Sign in as the child Apple ID, parent device nearby and unlocked, retry authorization | Parent approval prompt appears and is accepted. If it fails, enforcement is soft-lock only |

Then tap **Clear Shield** and confirm every app becomes usable again — leaving a
shield applied on someone's machine is the one destructive thing this test can do.

Record what you saw in `TEST_RESULTS.md` (screen-73f) and update
`CapabilityMatrix.macOS13Support()` accordingly.

### Installing the build

Xcode cannot run on Ventura, so the app is built elsewhere and copied over:

```bash
# On the build machine (Xcode 16, macOS 14.5+):
xcodebuild -scheme ScreenTimeScheduler \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -configuration Debug ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build

# Copy ScreenTimeScheduler.app to the iMac, then on the iMac:
xattr -dr com.apple.quarantine ScreenTimeScheduler.app
open ScreenTimeScheduler.app
```

The build must be x86_64 — the 2017 iMac is Intel — and signed with a profile
containing the iMac's Provisioning UDID, or it will refuse to launch.

---

**One-line plan (historical):** Read this document → install prereqs → run probe
app → follow test steps → update `CapabilityMatrix.swift`.

---

## Required hardware and OS

| Item | Requirement |
|------|-------------|
| Mac | iMac 2017 (the specific platform under test) |
| macOS | 13 Ventura — **not** 14 Sonoma or later |

> The capability gaps being verified (PLAN.md risks 9, 11, and sleep/wake DAM)
> are specific to the first-generation macOS ManagedSettings implementation.
> Testing on a newer OS will not expose them.

---

## On the Mac doing the build

This can be the iMac itself or a separate Mac that deploys to it.

### Xcode
- Xcode 15 or later (minimum version that supports a macOS 13 deployment target reliably)
- In **Xcode → Settings → Accounts**, add the Apple ID that holds the Developer
  Program membership

### Apple Developer Program
- Active membership ($99/yr) — required for the development variant of the
  `com.apple.developer.family-controls` entitlement
- The entitlement is auto-granted for development builds; no App Store review
  is required
- In **Xcode → target → Signing & Capabilities**, set Team to the Developer
  Program account; the entitlement lives in
  `ScreenTimeScheduler/App/macOS/ScreenTimeSchedulerMac.entitlements`

---

## On the iMac under test

### macOS
macOS 13 Ventura must be installed.  Check via **Apple menu → About This Mac**.

### iCloud account
The Apple ID signed in to iCloud on the iMac determines which probes can run:

| Test | Required iCloud account |
|------|------------------------|
| `familyControlsChildAuth` (screen-8ky) | Child's Apple ID (a Family Sharing member whose Screen Time is managed by a parent) |
| `atomicPerTokenUnshield` (screen-72b) | Any Apple ID; `.individual` authorization suffices |
| `CapabilityMatrix` unknowns (screen-n4v) | Child's Apple ID preferred for complete coverage |
| Per-token shield (screen-uc3) | Any Apple ID with FamilyControls authorized |

Sign in at **System Settings → Apple ID**.

### Family Sharing configuration
Required only for the `familyControlsChildAuth` probe:

1. The parent Apple ID must have the child Apple ID in their Family group
   (**iCloud.com → Family Sharing** or **Settings → Family**)
2. The parent must have set a Screen Time passcode for the child's account
3. A parent device (iPhone or Mac, signed in to the parent Apple ID) must be
   **nearby and unlocked** during the test — the `.child` authorization request
   triggers an approval prompt on the parent device

### Console.app
Open Console.app and add a filter:

- **Subsystem**: `net.emclain.ScreenScheduler`

Leave it running during all tests. OSLog output from `CapabilityProbe` and
DeviceActivityMonitor callbacks appears here.

---

## Running the tests

### Step 1 — Build and deploy

1. Open `ScreenTimeScheduler.xcodeproj` in Xcode on the build Mac
2. Select the **macOS** scheme and the iMac as the run destination
3. Build and run (**⌘R**); Xcode will install and launch the app on the iMac
   - If building on a separate Mac: use **Product → Archive**, then export and
     copy the `.app` to the iMac and open it there

### Step 2 — Run automated probes

In the app, locate the **Probe** section (or the "Run Probes" button in the
CapabilityProbe UI) and tap it.  The probe runs three checks:

1. **shieldApplicationsPerTokenUnshield** — verifies that
   `ManagedSettingsStore` accepts nil/empty write transitions without error.
   Full per-token verification requires real `ApplicationToken`s from
   `FamilyActivityPicker` (see Step 3).
2. **familyControlsChildAuth** — attempts `.child` authorization.  Requires the
   child Apple ID to be signed in (see iCloud account table above).
3. **deviceActivityReliableAcrossSleep** — logs a manual reminder; the
   automated probe cannot cover this path.

Watch Console.app for the `CapabilityProbe complete:` log entry.  Copy it
somewhere before moving on.

### Step 3 — Per-token shield test (manual, screen-uc3)

1. Open the **ScheduleEditorView** in the app and complete the onboarding flow
2. Use `FamilyActivityPicker` to select exactly **two apps**
3. Confirm both apps are shielded (verify in the picker output or Console.app)
4. Use the app's "Remove Shield" action for exactly **one** of the two apps
5. Confirm only the remaining app is still shielded

Expected on macOS 13: if `atomicPerTokenUnshield` is supported, one app is
shielded and the other is not.  If it is not supported, either both remain
shielded or the entire shield is cleared.

### Step 4 — Sleep/wake DAM callback test (manual)

1. Ensure at least one active `DeviceActivitySchedule` is registered (created
   during Step 3 onboarding)
2. Put the iMac to sleep: **Apple menu → Sleep**
3. Wait at least 60 seconds
4. Wake the iMac
5. Watch Console.app for a `DeviceActivityMonitor` `intervalDidStart` callback
   within 2 minutes of wake

Expected: the callback fires within 2 minutes (the LaunchAgent wake-nudge is
the mitigation for this known risk — PLAN.md §Platform Notes).

### Step 5 — Update CapabilityMatrix.swift

Open
`ScreenTimeScheduler/Core/Scheduling/CapabilityMatrix.swift` and replace the
`.unknown` entries in `macOS13Support()` with the observed values:

| Entry | Possible values |
|-------|----------------|
| `.atomicPerTokenUnshield` | `.enforced` / `.silentNoOp` / `.crashes` |
| `.damCallbacksReliableAcrossSleepWake` | `.enforced` / `.silentNoOp` |
| `.familyControlsChildAuth` | `.enforced` / `.crashes` / `.silentNoOp` |

Commit the updated file and close the corresponding bead(s).
