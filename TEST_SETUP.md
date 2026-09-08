# Hardware Test Setup — iMac 2017 / macOS 13 Ventura

This document tells you everything you need before running the hardware
verification tests (screen-72b, screen-8ky, screen-n4v, screen-uc3).

**One-line plan:** Read this document → install prereqs → run probe app → follow
test steps → update `CapabilityMatrix.swift`.

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

- **Subsystem**: `com.example.screen-time-scheduler`

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
