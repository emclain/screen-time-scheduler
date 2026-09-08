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

**No app is needed on the parent's device.** `.child` approval is Apple's own
system flow, not anything this project builds. The parent's **Screen Time
passcode** is what grants it, and it is typed into a system sheet **on the iMac**
(RESEARCH.md §1: "the parent-passcode approval flow on the child device").

What must be true:

1. The iMac is signed in to the **child's** Apple ID
2. That account is a member of the parent's Family Sharing group
3. **Screen Time is enabled for that child, with a passcode the parent set** — if
   Screen Time was never turned on for the account, gate 4 cannot run at all
4. Someone present knows that passcode

Have a parent device nearby anyway. Some OS versions route the approval to the
parent's device as a notification instead of prompting locally, and it costs
nothing to have it available. It does **not** need this app installed.

Nothing else from the parent half of the system — CloudKit sync, AFMT approval,
the parent-context picker — is involved in gates 0–4. App selection for gate 1
happens on the iMac itself, because tokens are device-scoped and must be picked
on the device that will enforce them (RESEARCH.md §1, PLAN.md bootstrap step 4).

### The build machine — not the iMac
- macOS 14.5 or later with **Xcode 16**. Not Xcode 26: it drops the Screen Time
  APIs entirely (`screen-b5g`).
- Active Apple Developer Program membership. This grants the *development*
  variant of `com.apple.developer.family-controls` automatically — no review.
  The entitlement lives in
  `ScreenTimeScheduler/App/iOS/ScreenTimeScheduler.entitlements` (the Catalyst
  build uses the iOS target).

### Logging, on the iMac
Without Xcode there is no debugger and no crash UI, so the log is the only
evidence channel you have. **Prefer Terminal over Console.app:**

```bash
# live, while you run the gates
log stream --predicate 'subsystem == "net.emclain.ScreenScheduler"' --info --debug

# after the fact, to recover what you missed
log show --last 30m --predicate 'subsystem == "net.emclain.ScreenScheduler"' --info --debug
```

Categories in use: `auth`, `shield`, `dam`, `sync`.

If you do use Console.app, filter **Subsystem** = `net.emclain.ScreenScheduler`
**and turn on Action → Include Info Messages.** Console hides info-level messages
by default and shows error-level ones, so a failing operation appears in the log
while the surrounding context does not — which reads as "it only logged once and
never again". The app now logs at notice level to avoid this, but older builds
and Apple's own subsystems still emit info.

The app also shows authorization status and the last authorization error on
screen, so you are not dependent on the log for gate 0.

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

The app shows **Authorization: <status>** and offers both **Request .individual**
and **Request .child**. Both buttons stay available in every state, so you can
always retry.

Which to use depends on the account signed in to the iMac:

- adult / non-managed Apple ID -> `.individual`
- Family Sharing child Apple ID -> `.child`

**A managed child account cannot self-authorize `.individual`.** Requesting it
throws `FamilyControlsError.restricted`, which looks like a platform failure and
is not one.

Interpreting the outcome — these are three different results, do not conflate them:

| Observed | Means |
|----------|-------|
| Status becomes `approved` | Gate 0 passes; continue |
| `error=restricted` | The daemon answered and refused *this request*. Usually the account type is wrong for the member you asked for, or Screen Time content & privacy restrictions / MDM are active. **The framework is alive** — try the other member, and check System Settings → Screen Time |
| `error=invalidAccountType` | Wrong member for this account; try the other button |
| No response, or `FamilyControlsAgent` connection errors (`4099`, error `159`, "No such process") | The daemon is absent or refusing outright. This is the macOS 26 / VM failure. **Only this is a complete answer to `screen-8ia`** — record it and stop |

A semantic error such as `restricted` is meaningfully *better* news than silence:
it means `FamilyControlsAgent` is present and responding on Ventura, which is
exactly what macOS 26 does not do.

#### Troubleshooting `restricted`

Observed on the iMac 2017 (2026-09-08): **both** `.individual` and `.child` return
`restricted` / "Family Controls is restricted", promptly rather than hanging.

`restricted` means the request reached the daemon and was refused by **policy**,
so the question is which policy. Our app only sees the opaque enum — the agent
logs its own reason. Capture that first, before changing any settings:

```bash
# In one Terminal, then click the button in the app:
log stream --predicate 'process == "FamilyControlsAgent" OR subsystem BEGINSWITH "com.apple.FamilyControls"' --info --debug

# Or after the fact:
log show --last 10m --predicate 'process == "FamilyControlsAgent" OR subsystem BEGINSWITH "com.apple.FamilyControls"' --info --debug
```

Then work through the policy candidates, on the iMac, retrying after each:

1. **Is Screen Time on for this account?** System Settings → Screen Time. If it
   was never enabled there is no policy for a third party to attach to. Turn it
   on and retry.
2. **Content & Privacy Restrictions.** If enabled, it can restrict Family Controls
   outright. Note the current state, turn it off (needs the Screen Time passcode),
   retry, and turn it back on afterwards.
3. **Is Screen Time managed by the parent?** The pane should say so. A child whose
   Screen Time is managed remotely behaves differently from one managed locally.
4. **Device management / configuration profiles.** System Settings → Privacy &
   Security → Profiles, or `profiles list`. An MDM profile — a school-issued one,
   for instance — can restrict Family Controls, and a Managed Apple ID (Apple
   School Manager) will refuse third-party Screen Time regardless of Family
   Sharing.
5. **Account age.** Family Sharing distinguishes a true child account from a
   standard Apple ID that happens to be in the family group. If the account was
   created as, or converted to, a regular Apple ID, `.child` may not apply — see
   `screen-rdz` on under-13 Apple ID quirks.

Record which of these was true even if none of them fixes it. "Both members
return `restricted` with Screen Time enabled, no restrictions, no MDM" is a much
stronger result for `screen-8ia` than "it did not work".

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
