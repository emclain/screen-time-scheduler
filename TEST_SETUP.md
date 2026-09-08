# Hardware Test Setup — iMac 2017 / macOS 13 Ventura

The purpose of this visit is to answer one question: **is there any usable
Screen Time enforcement path on the child's iMac?** Everything here gates the
decision in bead `screen-8ia` (keep, redesign, or drop the Mac target).

Five things must all break your way. They are ordered so that the cheapest and
most likely to fail come first — if one fails, the rest are moot and the Mac
path is dead as designed. Expect to know inside fifteen minutes.

## Why the procedure looks like this

Worth understanding before you start, because it explains why you are not using
Xcode at the machine and not running any probe:

- **The native macOS target cannot do this.** `ManagedSettingsStore` and
  `AuthorizationCenter` are `@available(macOS, unavailable)` even in the Xcode 16
  SDK. Native Mac enforcement has never been possible.
- **Mac Catalyst is the only path**, and Catalyst cannot host the
  DeviceActivityMonitor, ShieldConfiguration or ShieldAction extension points
  (`screen-j49`). So on a Mac there is no scheduled enforcement, no custom shield
  UI, and no shield-tap actions — only shields written directly by the running app.
- **Xcode cannot run on Ventura.** Xcode 16 requires macOS 14.5+. You build
  elsewhere and copy the app over, and Console.app is your only instrument.

---

## Prerequisites

### The iMac under test
- macOS 13 Ventura (**Apple menu → About This Mac**)
- Registered in the developer portal. Its Provisioning UDID
  (**System Information → Hardware → Provisioning UDID**) must appear in the
  signing profile. Currently `05FBC0EA-E036-5828-83DC-C58DA1F0337D`, confirmed
  present in the staged build's embedded profile.
- Signed in to iCloud — **which account depends on how far you get**:

  | Gates | Required iCloud account |
  |-------|-------------------------|
  | 0–3 (auth, picker, shield, per-token) | Any Apple ID; `.individual` is enough |
  | 4 (`.child` authorization) | The child's Apple ID, a Family Sharing member managed by a parent |

### Family Sharing — only for gate 4
1. The parent Apple ID has the child in their Family group
2. The parent has set a Screen Time passcode for the child's account
3. A parent device (iPhone or Mac, signed in to the parent Apple ID) is **nearby
   and unlocked** — `.child` triggers an approval prompt there

### The build machine — not the iMac
- macOS 14.5 or later with **Xcode 16**. Not Xcode 26: it drops the Screen Time
  APIs entirely (`screen-b5g`).
- Active Apple Developer Program membership. This grants the *development*
  variant of `com.apple.developer.family-controls` automatically — no review.
  The entitlement lives in
  `ScreenTimeScheduler/App/iOS/ScreenTimeScheduler.entitlements` (the Catalyst
  build uses the iOS target).

### Console.app, on the iMac
Open it before first launch and filter **Subsystem** =
`net.emclain.ScreenScheduler`. Categories in use: `auth`, `shield`, `dam`, `sync`.

Leave it running throughout. Without Xcode there is no debugger and no crash UI,
so this is the only evidence channel you have.

---

## Build and install

```bash
# On the build machine:
xcodebuild -scheme ScreenTimeScheduler \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -configuration Debug ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build
```

`ARCHS=x86_64` is mandatory — the 2017 iMac is Intel, and a Mac with Apple
silicon will otherwise build arm64 only.

Copy `ScreenTimeScheduler.app` to the iMac, then on the iMac:

```bash
xattr -dr com.apple.quarantine ScreenTimeScheduler.app
open ScreenTimeScheduler.app
```

Sanity checks if it refuses to launch:

```bash
codesign --verify --deep --strict ScreenTimeScheduler.app
security cms -D -i ScreenTimeScheduler.app/Contents/embedded.provisionprofile
```

The profile must list this iMac's UDID, and the signing certificate must be one
whose private key was on the build machine.

**Expected noise at launch:** the app calls `DeviceActivityCenter.startMonitoring`
on every start, guarded by `#if os(iOS)` — which is *true* under Catalyst. With no
monitor extension present this logs a schedule-registration failure. It is caught
and logged only. Do not read it as a symptom.

---

## The gates

Run in order. Stop when one fails — that failure is the result.

### Gate 0 — Does FamilyControls authorize at all on Ventura?

Tap **Request Authorization** (requests `.individual`).

- **Pass:** status flips to "Authorized"; Console shows `auth_granted`.
- **Fail:** status stays Not Determined, with `FamilyControlsAgent` errors in
  Console. This is what happens on macOS 26 and in a VM, where the daemon refuses
  or is absent. If it fails here, there is no third-party Screen Time on this Mac
  and gates 1–4 cannot run. **That is a complete answer to `screen-8ia`** — record
  it and stop.

### Gate 1 — Does `FamilyActivityPicker` enumerate Mac apps?

Tap **Choose Apps to Block**.

- **Pass:** the picker lists real applications. Record *which kinds*: native Mac
  apps (Safari, Finder, Mail), Catalyst apps, or only iOS-style entries.
- **Fail:** empty, or nothing corresponding to real Mac software. If there is
  nothing meaningful to select, there is nothing to shield — stop.

Select 2–3 apps you can safely block, including at least one native Mac app.
Console shows `tokens_saved count=N`.

### Gate 2 — Do shields actually block on a Mac?

Tap **Apply Shield to Selected**. Try to launch each picked app.

- **Pass:** the apps refuse to run and show Apple's default restricted screen.
  Console shows `shield_applied count=N`.
- **Fail:** apps launch normally. The write succeeded but enforced nothing —
  a silent no-op, the outcome the CapabilityMatrix calls `.silentNoOp`.

Record whether native and Catalyst apps behave differently. That distinction
decides whether the Mac can block anything the child actually uses.

### Gate 3 — Per-token unshield (PLAN.md risk 11)

With several apps shielded, tap **Unshield One App**.

- **Pass:** exactly one app becomes usable while the others stay blocked.
  Console shows `shield_token_removed remaining=N`.
- **Fail:** all apps unblock, or none do. Then app-scoped override grants are
  impossible on this platform and `OverrideEngine` must widen any app-scoped
  grant to its whole group.

### Gate 4 — Does `.child` authorization work?

Requires the child Apple ID signed in and a parent device nearby and unlocked.

- **Pass:** an approval prompt appears on the parent device; once approved, the
  app cannot be removed or deauthorized without the parent's Screen Time passcode.
  This is the only route to tamper-resistant enforcement.
- **Fail:** enforcement degrades to `.individual`, which the child can revoke from
  System Settings at any time with no passcode — a focus aid, not a parental
  control.

---

## Before you leave

**Tap Clear Shield and confirm every app launches again.**

Applying a shield is the only destructive thing this procedure does, and with no
ShieldAction extension there is no escape hatch from the shield screen itself. An
app left shielded stays shielded until this app clears it.

---

## Recording results

1. Write what you observed into `TEST_RESULTS.md` (`screen-73f`) — including
   failures and exact Console text, which is the whole point of the trip.
2. Update `CapabilityMatrix.swift`:

   | Entry | Set from | Values |
   |-------|----------|--------|
   | `.shieldApplications` | Gate 2 | `.enforced` / `.silentNoOp` — currently assumed `.enforced`, never verified |
   | `.atomicPerTokenUnshield` | Gate 3 | `.enforced` / `.silentNoOp` / `.crashes` |
   | `.familyControlsChildAuth` | Gate 4 | `.enforced` / `.crashes` / `.silentNoOp` |
   | `.damCallbacksReliableAcrossSleepWake` | — | **Not answerable on a Mac.** The extension point does not exist on Catalyst; this is an iPad question now |

   Note `screen-krb` first: `Platform.current` reports Catalyst as `.iOS`, so
   `macOS13Support()` is currently unreachable from the Mac build and editing it
   alone will not change what the app believes.

3. Close the beads the run settles — `screen-12v`, `screen-rjz`, `screen-uc3`,
   `screen-be8`, `screen-n4v` — and record the outcome on `screen-8ia`, which is
   the decision this all feeds.
