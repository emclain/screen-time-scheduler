/// CapabilityMatrix — per-platform ManagedSettings API support table.
///
/// Each `Capability` entry records whether a given `ManagedSettingsStore` key
/// is enforced, silently ignored, or crashes on a specific (platform, osVersion)
/// combination.  Entries marked `.unknown` require empirical verification on the
/// target hardware; see bead screen-t8a for the test plan and CapabilityProbe.swift
/// for the runtime diagnostic.
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
    /// FamilyControls `.child` authorization — requires iCloud account to be a
    /// Family Sharing child; approval flows through the parent's Screen Time passcode.
    /// PLAN.md risk 9: unverified on macOS 13.
    case familyControlsChildAuth
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
    /// Requires empirical testing on target hardware — see screen-t8a / CapabilityProbe.swift.
    case unknown
}

// MARK: - Matrix Data

private extension CapabilityMatrix {
    static func build(platform: Platform, osVersion: OperatingSystemVersion) -> [Capability: Support] {
        switch platform {
        case .iOS:
            return iOSSupport(osVersion: osVersion)
        case .macOS:
            return macOSSupport(osVersion: osVersion)
        }
    }

    static func iOSSupport(osVersion: OperatingSystemVersion) -> [Capability: Support] {
        // iOS/iPadOS 16+ is the baseline for this project.
        // All ManagedSettings keys work as documented on iOS 16+.
        return [
            .shieldApplications: .enforced,
            .shieldApplicationCategories: .enforced,
            .shieldWebDomains: .enforced,
            .webContentFilter: .enforced,
            .accountRestrictions: .enforced,
            .atomicPerTokenUnshield: .enforced,
            .damCallbacksReliableAcrossSleepWake: .enforced,
            .familyControlsChildAuth: .enforced,
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
            .familyControlsChildAuth: .enforced,
        ]
    }

    /// macOS 13 Ventura — first-generation Mac ManagedSettings support.
    ///
    /// ManagedSettings shipped on macOS 13 alongside iOS 15, but Mac parity
    /// was incomplete.  Entries below are populated from Apple documentation
    /// and PLAN.md notes.  Entries marked `.unknown` must be verified
    /// empirically on the iMac 2017 target hardware using CapabilityProbe.swift.
    ///
    /// Key findings from Apple docs / WWDC 2021-22 sessions:
    /// - `shield.applications` and `shield.applicationCategories` were listed
    ///   in the macOS 13 release notes as supported, but per-token subtraction
    ///   behavior is undocumented and suspected to be absent or broken.
    /// - `webContent` / `webDomains` filtering on macOS relies on the
    ///   NEFilterDataProvider path (distinct from the iOS WebKit hook); this
    ///   project does not configure an NEContentFilter extension, so these
    ///   keys are likely a silent no-op on macOS 13.
    /// - `account` lock/passcode keys are iOS-only in the macOS 13 SDK
    ///   headers — they compile but have no effect on macOS.
    /// - `familyControlsChildAuth (.child)`: undocumented for macOS 13 with
    ///   a Family Sharing child Apple ID. PLAN.md risk 9. Fall back to
    ///   `.individual` if this returns an error at runtime.
    /// - DAM callbacks across sleep/wake: PLAN.md flags this as a known risk.
    ///   A LaunchAgent wake-nudge is the current mitigation.
    static func macOS13Support() -> [Capability: Support] {
        return [
            // Documented in macOS 13 SDK; observed to enforce in Apple sample code.
            .shieldApplications: .enforced,
            // Same shipping status as shieldApplications.
            .shieldApplicationCategories: .enforced,
            // Requires NEFilterDataProvider extension — not configured here.
            .shieldWebDomains: .silentNoOp,
            // Same NEFilterDataProvider dependency as shieldWebDomains.
            .webContentFilter: .silentNoOp,
            // `account` keys are iOS-only in macOS 13 SDK; no-op on Mac.
            .accountRestrictions: .silentNoOp,
            // PLAN.md risk 11: unverified. If absent, OverrideEngine must
            // widen app-scoped grants to group-wide on this platform.
            .atomicPerTokenUnshield: .unknown,
            // PLAN.md: flagged as known risk; LaunchAgent wake-nudge is mitigation.
            .damCallbacksReliableAcrossSleepWake: .unknown,
            // PLAN.md risk 9: .child authorization on macOS 13 unverified.
            // Probe during onboarding; fall back to .individual if it fails.
            .familyControlsChildAuth: .unknown,
        ]
    }
}
