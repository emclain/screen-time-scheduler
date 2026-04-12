# Research: Programmatic Control of Apple Screen Time Downtime

## Goal
Identify Apple-supported (and unofficial) capabilities relevant to building a system that:
1. Defines multiple Downtime windows per day.
2. Supports one-day temporary overrides that auto-revert.
3. Manages schedules for the user **and** child accounts in a Family Sharing group.
4. Is controllable from iPhone and Mac.
5. Preserves the existing notification-driven "request more time" flow.

---

## 1. Apple's Screen Time API (iOS 16+ / macOS 13+)

Apple exposes Screen Time programmatically through three frameworks introduced at WWDC21 and expanded since:

| Framework | Purpose |
|---|---|
| **FamilyControls** | Authorization gateway, presents `FamilyActivityPicker` so the user (parent or self) opaquely selects apps/categories/web domains. Returns privacy-preserving `ApplicationToken` / `ActivityCategoryToken` / `WebDomainToken` values. |
| **ManagedSettings** | Applies the actual restrictions on the **local device only**: `shieldApplications`, `shieldApplicationCategories`, `webContent`, account/passcode locks, etc. Settings persist across reboots until cleared. |
| **DeviceActivity** | Schedules when restrictions apply. A `DeviceActivitySchedule` is a calendar interval (`intervalStart`, `intervalEnd`, `repeats`) that fires extension callbacks (`intervalDidStart`, `intervalDidEnd`, threshold events). |

### Key facts and constraints
- **Authorization modes**: `.individual` (user manages own device) and `.child` (only succeeds if signed-in iCloud account is a child in a Family Sharing group; approval is granted from the parent device via the standard Screen Time passcode flow). Once approved, the app cannot be removed without the guardian passcode.
- **Multiple windows per day**: A single `DeviceActivitySchedule` is one contiguous interval. The supported pattern is to register **multiple schedules under distinct `DeviceActivityName`s**, each starting/ending its own ManagedSettings store updates. (Apple Dev Forums thread 742131; community confirmation.)
- **Minimum interval**: 15 minutes. Schedules with hour/minute/second `DateComponents` only — adding day/weekday is unreliable.
- **Custom days of week**: Not directly supported in a single schedule. Workarounds: register seven schedules and decide in `intervalDidStart` whether to actually shield, or use a long-running daily monitor that re-applies settings based on the current weekday.
- **ManagedSettings is local**: Settings written by code on the parent's device do **not** propagate to the child's device. Apple's own Screen Time UI uses iCloud sync for the system schedule, but third-party apps must build their own sync (CloudKit, push, etc.).
- **ApplicationToken portability**: Tokens are opaque and **device-scoped**. Tokens selected via `FamilyActivityPicker` on a parent device **cannot be applied** on the child device — they're meaningless there. The picker must be presented on the device where the shield will be enforced (or via the parent->child picker flow Apple added in iOS 16, which returns tokens valid on the child device but only when launched in that specific guardian context).
- **Background execution**: DeviceActivityMonitor extensions run in a tightly sandboxed background process; you can re-write the `ManagedSettingsStore` and schedule new monitors there.
- **Entitlement**: `com.apple.developer.family-controls` has two variants — *development* (auto-granted with a paid Apple Developer Program membership, no application) and *distribution* (requires Apple's manual review, often slow). For a household tool that is never distributed via TestFlight or the App Store, the development variant is sufficient — see §10 below.
- **macOS support**: FamilyControls / ManagedSettings / DeviceActivity are available on macOS 13+ with similar semantics. SwiftUI multi-platform app feasible.
- **Notification "request more time" flow**: Implemented entirely by Apple's system Screen Time. It is **orthogonal** to ManagedSettings shields written by a third-party app — but if a third-party shield is active, the system Ask-for-More-Time UI does not unlock it. To preserve the existing flow, the system Downtime should remain the source of truth for the user-visible block, **or** the third-party app must implement its own request/approval channel.

### Implications for "multiple windows"
Two viable strategies:
- **A. Replace system Downtime**: turn the OS schedule off; let the third-party app shield via ManagedSettings on multiple `DeviceActivitySchedule`s. Maximum control but **loses Apple's request-more-time UI**.
- **B. Drive system Downtime**: at the start of each window, use automation to enable system Downtime; at end, disable it. Preserves Ask-for-More-Time, but requires a way to toggle the system setting (no public API for this — only Shortcuts/MDM, see below).

---

## 2. Shortcuts / Focus / Automation
- The Shortcuts app exposes a `Set Focus` action and a `Do Not Disturb` toggle, but **no first-party action to toggle Screen Time Downtime on/off** as of iOS 18/26. There are deep-link shortcuts that *open* the Downtime settings page but cannot flip the toggle.
- Automations can run silently on iOS 15+ ("Run immediately, no notification").
- A Mac can run Shortcuts on a schedule via `launchd`/Calendar.
- Conclusion: Shortcuts alone cannot programmatically toggle system Downtime.

## 3. MDM / Configuration Profiles
- Apple's MDM protocol supports a `com.apple.screentime` payload (and `Restrictions` payloads) that can push Screen Time configuration to supervised devices and to family-member devices on supported MDM solutions.
- Configuration profiles can be installed/removed to flip schedules, and can target child devices via Apple Business/School Manager — but **family-only (consumer) devices are not supervised**, so MDM is generally not viable for a single family unless the parent operates their own MDM and supervises devices via Apple Configurator. Heavy and intrusive.

## 4. Family Sharing & Cross-Device Control
- Apple's own Screen Time syncs the **system** schedule for a child across all the child's devices via iCloud (the "Share Across Devices" toggle).
- A third-party Family Controls app installed on the parent's device can present `FamilyActivityPicker(.child)` to pick apps for the child, but tokens returned must be transmitted to the child device, where a sibling app must be installed and approved. Apple does **not** provide a transport — developers use CloudKit, APNs, or a backend.
- For a parent → child shield to take effect, the same app must be installed on the child device and registered with Family Controls authorization `.child`.

### 4.1 CKShare behavior with child Apple IDs (under-13)

**Research finding (April 2026):** Despite multiple internal document references claiming "known CKShare-to-child quirks," no specific, documented Apple restriction on CKShare for child Apple IDs under 13 was found in Apple Developer Forums, official documentation, or developer blog posts.

**What IS documented:**
- **Sign in with Apple** is explicitly blocked for accounts under 13 (COPPA compliance). This does NOT affect CKShare.
- **Two-factor authentication** cannot be fully configured on child accounts, but this affects Sign in with Apple, not CloudKit sharing.
- **CKShare general limitations** exist (5,000 record hard limit at share creation time, recommended 200), but these apply to all accounts equally.
- **CKAcceptSharesOperation errors** (e.g., "Couldn't get a Sharing identity set") occur sporadically for all users, not specifically child accounts. These are typically transient or related to iCloud account setup issues.

**What is NOT documented:**
- No Apple documentation states that CKShare invitations fail or behave differently for under-13 child Apple IDs.
- No Developer Forum threads describe CKShare-specific failures tied to child account age.
- Apple's Family Privacy Disclosure explicitly states children "can create and share documents and data with other people through iCloud public and private sharing."

**Conclusion:** The QR-bootstrap-first design in PLAN_AB is **not** justified by documented CKShare restrictions. The design may still be useful for UX reasons (QR is simpler than email-based share links for young children), but the "unreliable CKShare-to-child" rationale appears unfounded. Testing with an actual under-13 child account in the Development CloudKit environment should confirm whether any undocumented restrictions exist.

**References:**
- Apple Family Privacy Disclosure: https://www.apple.com/legal/privacy/en-ww/parent-disclosure/
- Sign in with Apple restrictions: https://support.apple.com/en-us/102609
- CKShare documentation: https://developer.apple.com/documentation/cloudkit/ckshare

## 5. State of Third-Party Apps
- **Jomo**, **Opal**, **ScreenZen**, **One Sec**, **Brick**: actively maintained focus/blocker apps using FamilyControls. None offer multi-window Downtime *with* Apple's native Ask-for-More-Time. Most replace shields with their own.
- **ScreenBreak** (open source, github.com/christianp-622/ScreenBreak): reference iOS-16 implementation of the three frameworks.
- **react-native-device-activity** (kingstinct): bridges the frameworks to RN; useful as an API surface reference.
- Many earlier "Screen Time controller" projects (pre-iOS 16) are abandoned because they relied on private APIs.

## 6. Always-On Mac Considerations
- Mac can host a launchd-based scheduler that issues CloudKit/APNs writes consumed by iOS device(s).
- A macOS app using FamilyControls in `.individual` mode can shield apps on the Mac itself but cannot directly manipulate iOS devices.
- The Mac is most useful as the **authoritative scheduling brain + sync server**, not as an enforcement point for iOS.

---

## 7. Capability Summary

| Requirement | Achievable? | How |
|---|---|---|
| Multiple Downtime windows/day | Yes (third-party shielding) | Multiple `DeviceActivitySchedule`s + `ManagedSettingsStore` writes |
| Multiple Downtime windows/day **with native Ask-For-More-Time** | No (cleanly) | Apple offers no API to add windows to system Downtime |
| One-day temporary override | Yes | App-level state; on next `intervalDidStart` consult override store and skip/extend |
| Manage child accounts | Yes, with friction | Sibling app on child device, FamilyControls `.child` approval, CloudKit transport |
| Control from iPhone & Mac | Yes | Multiplatform SwiftUI app + CloudKit shared zone |
| Offline parent device | Yes if always-on Mac (or backend) hosts authoritative state |
| Preserve Ask-For-More-Time | Only by leaving system Downtime alone OR reimplementing the request flow in-app |

---

## 8. Open Questions / Risks
1. Apple entitlement approval lead time and policy (consumer-targeted family controls apps have been approved but reviewers are strict). **Mitigated for personal/household use by §9.**
2. Reliability of `DeviceActivityMonitor` background callbacks across device sleep/reboot — community reports occasional missed events.
3. Whether the user is willing to lose Apple's native Ask-For-More-Time UI in exchange for richer scheduling, or wants the app to reimplement that flow (notifications + approval round-trip via CloudKit/APNs).
4. macOS Screen Time has historically lagged iOS in API completeness — verify before committing to Mac-side enforcement.

---

## 9. Development-only entitlement path (single-developer household)

For this user — a developer with full physical control of every device that needs the app — Apple's slow distribution-entitlement review can be bypassed entirely by living permanently on the **development** code-signing path. This significantly weakens the deployment-cost critiques that PLAN_A and PLAN_B received and removes the App-Review-rejection risk from any in-app reimplementation of the request-more-time flow.

### What is unlocked without applying for the distribution entitlement
- **Paid Apple Developer Program membership ($99/year)** is sufficient. In Xcode's Signing & Capabilities pane, "Family Controls" appears as a checkable capability immediately; no application form, no review.
- **Development provisioning profiles** issued by Xcode automatically include `com.apple.developer.family-controls` once the capability is enabled on the App ID.
- **Full API surface works in development builds**: `FamilyControls`, `ManagedSettings`, `DeviceActivity`, `DeviceActivityMonitor` extension, `ShieldConfiguration` extension, `ShieldAction` extension. Both `.individual` and `.child` authorizations work, including the parent-passcode approval flow on the child device.
- **Install on any device registered to your developer account**: 100 iPhones, 100 iPads, 100 Macs per year. A family will use a handful. Devices are registered with one click in Xcode the first time you build to them.
- **Builds run indefinitely** — there is no 7-day expiry on a paid-account development build. The expiry that affects this path is the *provisioning profile* one (12 months); a rebuild + reinstall refreshes it.
- **Sibling app on the child's device** installs the same way (USB or Wi-Fi pairing). The `.child` authorization flow is enforced by iOS at runtime, not by entitlement state, so it behaves identically to a production app.
- **No App Review.** This eliminates a specific risk CRITIQUE_2 raised against PLAN_A: that a `ShieldActionExtension` reimplementing Apple's Ask-For-More-Time sheet would be rejected at review. There is no review.

### What is **not** available on the development path
- **TestFlight, App Store, ad-hoc, or notarized direct download**: all require a *distribution* provisioning profile, which requires the distribution variant of the entitlement, which requires Apple's manual approval. None of these are needed for a household tool the developer installs themselves.
- **Free Personal Team** (no $99 fee): Family Controls is on the personal-team blocklist; the capability is greyed out. The paid program is required.
- **Hand-off to a non-developer**: anyone who would otherwise install the app via TestFlight cannot. This path is exclusively for households where one person owns the build infrastructure and all the target devices.

### CloudKit on the development path
CloudKit containers exist in two parallel environments — **Development** and **Production** — and a build automatically uses the environment matching its code-signing type. Development builds → Development CloudKit; distribution builds → Production CloudKit. They are separate databases with separate schemas, both fully iCloud-backed and end-to-end encrypted.

Implications for this project:
- Development CloudKit is created automatically with the container; no "deploy" step is required.
- Schema is **mutable forever** in Development — record types, fields, and indexes can be added, removed, or renamed at any time, even with running production users. Production schema, by contrast, is append-only.
- All CloudKit features behave identically in Development: private database, `CKShare` invitations to a child Apple ID, `CKQuerySubscription` silent pushes that wake `DeviceActivityMonitor` extensions, conflict resolution, etc. No documented CKShare restrictions exist for child Apple IDs (see §4.1).
- The CloudKit Dashboard (`icloud.developer.apple.com/dashboard`) exposes the Development environment for browsing records, editing the schema, and inspecting subscription deliveries — useful for debugging without instrumentation in the app itself.
- Quotas on Development are well above what a household-scale schedule store will ever consume.

In short: the entire CloudKit-based design in PLAN_A and PLAN_B can run permanently against the Development environment. There is never a need to click "Deploy Schema to Production."

### Operating costs of the development path
- **$99/year** Apple Developer Program renewal. Lapsing this revokes provisioning profiles on next device check-in.
- **Annual rebuild**: development provisioning profiles expire after 12 months. The installed app keeps running until iOS revalidates the profile, but the safe practice is a calendar reminder to rebuild and reinstall yearly. Per device. ~10 minutes per device per year.
- **Each new family device** must be registered to the developer account once and installed-to once via cable or Wi-Fi pairing. Within the per-year device-slot quota for a household.
- **macOS app/daemon**: installs from Xcode the same way; the development entitlement covers macOS targets equivalently. (The macOS-Screen-Time-API-parity caveat in §6 still applies — that is a runtime API gap, not an entitlement gap.)

### Effect on plan ranking
- PLAN_A and PLAN_B both become substantially cheaper to ship. The "6 weeks of entitlement review" overhead in CRITIQUE_1/2 drops to zero. The "App Review may reject the AFMT-imitating ShieldActionExtension" risk in CRITIQUE_2 also drops to zero.
- PLAN_C is unaffected — it does not use FamilyControls and the entitlement question never applied to it. Its blockers (supervision wipe, MDM vendor cert) are separate Apple gates that the development entitlement path does not address.
- The remaining critiques against A and B (the `.systemDowntimeMirror` fiction in A; the daemon-can't-hold-FamilyControls-auth issue in B; the AFMT-only-on-one-window honesty problem common to both; the DeviceActivityMonitor reliability concerns) are unchanged.

### Key references for §9
- Apple: Configuring Family Controls — https://developer.apple.com/documentation/xcode/configuring-family-controls
- Apple: Requesting the Family Controls entitlement — https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement
- Apple Dev Forum: development vs distribution Family Controls profiles — https://developer.apple.com/forums/thread/701874
- Apple Dev Forum: TestFlight requires the distribution entitlement — https://developer.apple.com/forums/thread/712870

---

## 10. Key References
- Apple: Screen Time Technology Frameworks — https://developer.apple.com/documentation/screentimeapidocumentation
- Apple: FamilyControls — https://developer.apple.com/documentation/familycontrols
- Apple: DeviceActivitySchedule — https://developer.apple.com/documentation/deviceactivity/deviceactivityschedule
- Apple: ManagedSettings + Family Sharing — https://developer.apple.com/documentation/managedsettings/connectionwithframeworks
- Apple Dev Forum: "Multiple Days Schedules" — https://developer.apple.com/forums/thread/742131
- Apple Dev Forum: "DeviceActivitySchedule DateComponents intervals" — https://developer.apple.com/forums/thread/729841
- Apple Dev Forum: ApplicationToken cross-device issue — https://developer.apple.com/forums/thread/720847
- WWDC21 "Meet the Screen Time API" — https://developer.apple.com/videos/play/wwdc2021/10123/
- Julius Brussee, Developer's Guide — https://medium.com/@juliusbrussee/a-developers-guide-to-apple-s-screen-time-apis-familycontrols-managedsettings-deviceactivity-e660147367d7
- ScreenBreak reference impl — https://github.com/christianp-622/ScreenBreak
- react-native-device-activity — https://github.com/kingstinct/react-native-device-activity
