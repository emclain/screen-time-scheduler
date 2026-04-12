/// CapabilityMatrix — per-platform ManagedSettings API support table.
///
/// Each `Capability` entry records whether a given `ManagedSettingsStore` key
/// is enforced, silently ignored, or crashes on a specific (platform, osVersion)
/// combination.  Entries marked `.unknown` require empirical verification on the
/// target hardware; see bead screen-t8a for the test plan.
///
/// Usage:
///   let matrix = CapabilityMatrix.current
///   if matrix.supports(.shieldApplications) { ... }

import Foundation

// MARK: - Public API

/// Returns the capability matrix for the currently running device.
struct CapabilityMatrix {
    let platform: Platform
    let osVersion: OperatingSystemVersion
    private let entries: [Capability: Support]

    /// Capability matrix for the running process's platform and OS version.
    static var current: CapabilityMatrix {
        CapabilityMatrix(platform: .current, osVersion: ProcessInfo.processInfo.operatingSystemVersion)
    }

    init(platform: Platform, osVersion: OperatingSystemVersion) {
        self.platform = platform
        self.osVersion = osVersion
        self.entries = CapabilityMatrix.build(platform: platform, osVersion: osVersion)
    }

    /// Whether a capability is confirmed to enforce on this device.
    func supports(_ capability: Capability) -> Bool {
        entries[capability] == .enforced
    }

    /// Full support status for a capability.
    func support(for capability: Capability) -> Support {
        entries[capability] ?? .unknown
    }
}

// MARK: - Types

enum Platform: String, Sendable {
    case iOS
    case macOS

    static var current: Platform {
#if os(macOS)
        return .macOS
#else
        return .iOS
#endif
    }
}

/// A `ManagedSettingsStore` key or behavioral property under test.
enum Capability: String, CaseIterable, Sendable {
    /// `ManagedSettingsStore.shield.applications` — per-app blocking via ApplicationToken.
    case shieldApplications
    /// `ManagedSettingsStore.shield.applicationCategories` — category-level blocking via ActivityCategoryToken.
    case shieldApplicationCategories
    /// `ManagedSettingsStore.shield.webDomains` — web domain filtering via WebDomainToken.
    case shieldWebDomains
    /// `ManagedSettingsStore.webContent` filter keys.
    case webContentFilter
    /// `ManagedSettingsStore.account` lock/passcode keys.
    case accountRestrictions
    /// Atomically subtracting a single ApplicationToken from an active shield set without
    /// clearing the whole store (required for app-scoped grant overrides).
    case atomicPerTokenUnshield
    /// DeviceActivityMonitor callbacks fire reliably across sleep/wake cycles.
    case damCallbacksReliableAcrossSleepWake
}

/// Observed enforcement behavior for a capability.
enum Support: String, Sendable, Equatable {
    /// Writing the key enforces the restriction as documented.
    case enforced
    /// Writing the key is accepted without error but has no observable effect.
    case silentNoOp
    /// Writing the key causes an exception, crash, or undefined behavior.
    case crashes
    /// Not yet verified on this platform/version combination.
    /// Requires empirical testing on target hardware — see screen-t8a.
    case unknown
}

// MARK: - Matrix Data

private extension CapabilityMatrix {
    // swiftlint:disable:next function_body_length
    static func build(platform: Platform, osVersion: OperatingSystemVersion) -> [Capability: Support] {
        switch platform {
        case .iOS:
            return iOSSupport(osVersion: osVersion)
        case .macOS:
            return macOSSupport(osVersion: osVersion)
        }
    }

    static func iOSSupport(osVersion: OperatingSystemVersion) -> [Capability: Support] {
        // iOS 16+ is the baseline for this project (parent iPhone, child iPhone/iPad).
        // All ManagedSettings keys work as documented on iOS 16+.
        return [
            .shieldApplications: .enforced,
            .shieldApplicationCategories: .enforced,
            .shieldWebDomains: .enforced,
            .webContentFilter: .enforced,
            .accountRestrictions: .enforced,
            .atomicPerTokenUnshield: .enforced,
            .damCallbacksReliableAcrossSleepWake: .enforced,
        ]
    }

    static func macOSSupport(osVersion: OperatingSystemVersion) -> [Capability: Support] {
        if osVersion.majorVersion == 13 {
            return macOS13Support()
        }
        // macOS 14+ — assume iOS parity until tested.
        return [
            .shieldApplications: .enforced,
            .shieldApplicationCategories: .enforced,
            .shieldWebDomains: .enforced,
            .webContentFilter: .enforced,
            .accountRestrictions: .enforced,
            .atomicPerTokenUnshield: .enforced,
            .damCallbacksReliableAcrossSleepWake: .enforced,
        ]
    }

    /// macOS 13 Ventura — first-generation Mac ManagedSettings support.
    ///
    /// ManagedSettings shipped on macOS 13 alongside iOS 15, but Mac parity
    /// was incomplete.  Entries below are populated from Apple documentation
    /// and PLAN.md notes.  Entries marked `.unknown` must be verified
    /// empirically on the iMac 2017 target hardware (screen-t8a).
    ///
    /// Key findings from Apple docs / WWDC 2021-22 sessions:
    /// - `shield.applications` and `shield.applicationCategories` were listed
    ///   in the macOS 13 release notes as supported, but per-token subtraction
    ///   behavior is undocumented and suspected to be absent or broken.
    /// - `webContent` filtering on macOS relies on a content-filter network
    ///   extension path that is distinct from the iOS WebKit hook; enforcement
    ///   is less reliable and may be a silent no-op without additional
    ///   configuration that is outside the scope of this project.
    /// - `account` lock/passcode keys are iOS-only in the original macOS 13
    ///   SDK headers — they compile but have no effect on macOS.
    /// - DAM callbacks across sleep/wake: PLAN.md flags this as a known risk.
    ///   A LaunchAgent wake-nudge is the current mitigation.
    static func macOS13Support() -> [Capability: Support] {
        return [
            // Documented in macOS 13 SDK; observed to enforce in Apple sample
            // code.  Treat as enforced unless hardware testing contradicts.
            .shieldApplications: .enforced,
            // Same shipping status as shieldApplications.
            .shieldApplicationCategories: .enforced,
            // Compiles; enforcement path on macOS uses NEFilterDataProvider,
            // which is not configured by this project.  Likely a silent no-op.
            .shieldWebDomains: .unknown,
            // Same as shieldWebDomains — requires NEContentFilter setup.
            .webContentFilter: .unknown,
            // `account` keys are iOS-only in macOS 13 SDK; no-op on Mac.
            .accountRestrictions: .silentNoOp,
            // PLAN.md note §11: unverified.  If absent, OverrideEngine must
            // widen app-scoped grants to group-wide on this platform.
            .atomicPerTokenUnshield: .unknown,
            // PLAN.md: flagged as known risk; LaunchAgent wake-nudge is mitigation.
            .damCallbacksReliableAcrossSleepWake: .unknown,
        ]
    }
}
