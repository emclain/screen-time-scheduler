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
- **Entitlement**: `com.apple.developer.family-controls` requires Apple approval (often slow). Distribution requires it on both the app and any extensions.
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
1. Apple entitlement approval lead time and policy (consumer-targeted family controls apps have been approved but reviewers are strict).
2. Reliability of `DeviceActivityMonitor` background callbacks across device sleep/reboot — community reports occasional missed events.
3. Whether the user is willing to lose Apple's native Ask-For-More-Time UI in exchange for richer scheduling, or wants the app to reimplement that flow (notifications + approval round-trip via CloudKit/APNs).
4. macOS Screen Time has historically lagged iOS in API completeness — verify before committing to Mac-side enforcement.

---

## 9. Key References
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
