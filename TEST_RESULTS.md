# Test Results

Empirical findings from hardware. Each entry records what was run, what happened,
and what it settles. Negative results are the point — they are what keep the plan
honest.

---

## 2026-09-08 — iMac 2017 / macOS 13 Ventura / Mac Catalyst

**Verdict: gate 0 fails at the platform level. There is no third-party Screen
Time enforcement path on this Mac.**

### Setup

| | |
|---|---|
| Hardware | iMac 2017, Intel x86_64 |
| OS | macOS 13 Ventura |
| Build | Mac Catalyst, Debug, x86_64, development-signed |
| Entitlement | `com.apple.developer.family-controls` present in the signed binary |
| Profile | "Screen Scheduler mac", containing the iMac's Provisioning UDID |

Signature and entitlements were verified **on the iMac itself**, against the copy
that was actually launched — `codesign --verify --deep --strict` passed and
`codesign -d --entitlements` showed the entitlement. This mattered: the iMac is
Intel, and Intel Macs will launch an app whose signature is damaged, which would
have silently invalidated every result.

### Result

| Test | Account | Result |
|------|---------|--------|
| `requestAuthorization(for: .individual)` | Family Sharing child | `FamilyControlsError.restricted` |
| `requestAuthorization(for: .child)` | Family Sharing child | `restricted` — "Family Controls is restricted" |
| `requestAuthorization(for: .individual)` | Ordinary adult Apple ID | `restricted` |

In every case the call returned **promptly** — never hung — and
`authorizationStatus` never left `.notDetermined` (`changed=false`).

### What was eliminated

- **Content & Privacy Restrictions** — turned off, retried, no change; turned back on, no change
- **Screen Time not configured** — Screen Time is enabled; toggling C&P prompted for the Screen Time PIN, and the parent's device shows Screen Time for the child. The family setup is correct and working
- **Legacy parental controls** — the account is "Standard" in Users & Groups, not "Managed"
- **Broken signature or missing entitlement** — verified on the iMac, see above
- **Account type** — an ordinary adult account fails identically, which is what
  makes this a platform result rather than an account one

### Why this is a platform refusal

With `log stream` filtered on `process == "ScreenTimeScheduler"`, only the app's
own `auth_failed` lines appear — **the FamilyControls framework logs nothing**.
Filtering on the Screen Time daemons shows `parentalcontrolsd` and
`webfilterproxyd` active and chatty, but nothing referencing the app at any point.

The refusal is therefore generated **client-side, inside the FamilyControls
framework in the app's own process**, before any XPC to a daemon. Ventura
declines Family Controls to a Mac Catalyst app without ever asking the system.

> An earlier reading during this session — that a prompt `restricted` meant the
> agent was alive and answering, and was therefore encouraging — was wrong. A
> local pre-check produces an identical signature: prompt semantic error, no
> hang. The distinguishing evidence is the absence of any framework or daemon
> logging.

### Consequences

Gates 1–4 are unreachable. Nothing downstream of authorization can be tested on
this machine, so these remain permanently unanswered on macOS 13:

- whether `FamilyActivityPicker` enumerates Mac apps (gate 1)
- whether shields enforce on a Mac (gate 2)
- `atomicPerTokenUnshield` (gate 3, PLAN.md risk 11)
- `.child` authorization on macOS 13 (gate 4, PLAN.md risk 9)

Combined with the two paths already ruled out, every Mac route is now closed:

| Route | Status |
|-------|--------|
| Native macOS | `ManagedSettingsStore` / `AuthorizationCenter` are `@available(macOS, unavailable)` even in the Xcode 16 SDK. Never documented as supported |
| Mac Catalyst, macOS 13 | Compiles and links, but authorization is refused client-side regardless of account — **this result** |
| Mac Catalyst, macOS 26 | Key symbols marked `macCatalyst, unavailable`; won't compile |
| Designed for iPad, macOS 26 | Runs, but `FamilyControlsAgent` refuses with sandbox error 4099 / 159 |

Feeds the decision in `screen-8ia`.

### Scope limits

- One machine, one OS version. Not tested on Apple silicon running Ventura, so
  this does not establish whether the refusal is Intel-specific. It does not
  matter for this project — the target device *is* this Intel iMac
- The app was launched from a copied bundle rather than `/Applications`. Not
  expected to produce `restricted`, and untested
