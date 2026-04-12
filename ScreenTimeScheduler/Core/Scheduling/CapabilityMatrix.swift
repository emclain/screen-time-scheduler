import Foundation

// CapabilityMatrix — per-platform ManagedSettings shield capability table.
//
// Sources of truth:
//   - Apple Developer Documentation (ManagedSettings, FamilyControls, DeviceActivity)
//   - PLAN.md §Open Risks, specifically risks 7, 9, 11
//   - Empirical probing on target hardware (see CapabilityProbe.swift for the
//     diagnostic tool that populates the UNVERIFIED entries below)
//
// Verification status legend:
//   .docVerified  — matches Apple's published API docs for this OS version
//   .untested     — compiles and the API exists, but not confirmed to enforce
//   .unavailable  — API is absent or known no-op on this platform (docs + testing)
//   .empirical    — confirmed by running CapabilityProbe on actual hardware
//
// macOS 13 Ventura open risks (from PLAN.md):
//   Risk 9:  FamilyControls .child availability — unverified
//   Risk 11: Per-token unshield (subtract one ApplicationToken from active shield) — unverified

// MARK: - Types

/// A ManagedSettings shield capability that CapabilityMatrix tracks.
public enum ShieldCapability: String, CaseIterable, Sendable {
    /// shield.applications — block individual apps by ApplicationToken.
    case shieldApplications
    /// shield.applicationCategories — block app categories by ActivityCategoryToken.
    case shieldApplicationCategories
    /// Subtract a single ApplicationToken from the active shield set without
    /// clearing the whole shield — needed for app-scoped GrantOverrides.
    /// If unavailable, OverrideEngine widens app-scoped grants to group-wide.
    case shieldApplicationsPerTokenUnshield
    /// shield.webDomains — filter web domains by WebDomainToken.
    case shieldWebDomains
    /// account.lockAccounts / lockAccountModification — iOS/iPadOS only.
    case accountLock
    /// passcode.lockPasscode — iOS/iPadOS only.
    case passcodeLock
    /// FamilyControls .child authorization — requires iCloud account to be a
    /// Family Sharing child; approval flows through parent's Screen Time passcode.
    case familyControlsChildAuth
    /// DeviceActivityMonitor callbacks survive sleep/wake without manual wake-nudge.
    case deviceActivityReliableAcrossSleep
}

/// How a capability's status was determined.
public enum VerificationSource: String, Sendable {
    /// Matches published Apple API documentation for this OS/platform.
    case docVerified
    /// API compiles and exists; not confirmed to enforce on this device.
    case untested
    /// API is absent or a confirmed no-op; do not rely on it.
    case unavailable
    /// Confirmed by running CapabilityProbe on actual target hardware.
    case empirical
}

public struct CapabilityStatus: Sendable {
    public let supported: Bool
    public let source: VerificationSource
    /// Human-readable note, especially for PLAN.md open risks.
    public let note: String?

    public init(supported: Bool, source: VerificationSource, note: String? = nil) {
        self.supported = supported
        self.source = source
        self.note = note
    }
}

// MARK: - CapabilityMatrix

/// Static capability table keyed by (platform, osVersionMajor).
///
/// Usage:
///   let matrix = CapabilityMatrix.current
///   if matrix[.shieldApplicationsPerTokenUnshield].supported { ... }
public struct CapabilityMatrix: Sendable {
    public let platform: Platform
    public let osVersionMajor: Int
    private let table: [ShieldCapability: CapabilityStatus]

    public enum Platform: String, Sendable {
        case iOS
        case iPadOS
        case macOS
    }

    public subscript(_ capability: ShieldCapability) -> CapabilityStatus {
        table[capability] ?? CapabilityStatus(
            supported: false,
            source: .unavailable,
            note: "Not listed in capability table for \(platform.rawValue) \(osVersionMajor)"
        )
    }

    // MARK: Factory

    public static var current: CapabilityMatrix {
        #if os(macOS)
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return macOS(osVersionMajor: major)
        #elseif os(iOS)
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let idiom = UIDevice.current.userInterfaceIdiom
        if idiom == .pad {
            return iPadOS(osVersionMajor: major)
        } else {
            return iOS(osVersionMajor: major)
        }
        #else
        preconditionFailure("Unsupported platform")
        #endif
    }

    // MARK: - Platform tables

    // MARK: macOS 13 Ventura
    //
    // First-generation Mac ManagedSettings APIs. Treat all gaps as permanent —
    // the child iMac 2017 cannot run macOS 14+.
    //
    // UNVERIFIED items (marked .untested) must be confirmed by running
    // CapabilityProbe on the iMac 2017 before shipping:
    //   - shieldApplicationsPerTokenUnshield (PLAN.md risk 11)
    //   - familyControlsChildAuth            (PLAN.md risk 9)
    //   - deviceActivityReliableAcrossSleep  (PLAN.md §Platform Notes)
    static func macOS(osVersionMajor: Int) -> CapabilityMatrix {
        guard osVersionMajor >= 13 else {
            return CapabilityMatrix(platform: .macOS, osVersionMajor: osVersionMajor, table: [:])
        }
        let table: [ShieldCapability: CapabilityStatus] = [
            .shieldApplications: .init(
                supported: true,
                source: .docVerified,
                note: "ManagedSettingsStore.shield.applications documented for macOS 13+"
            ),
            .shieldApplicationCategories: .init(
                supported: true,
                source: .docVerified,
                note: "ManagedSettingsStore.shield.applicationCategories documented for macOS 13+"
            ),
            // PLAN.md risk 11 — unverified. OverrideEngine uses this flag:
            // if false it widens app-scoped grants to their enclosing group.
            .shieldApplicationsPerTokenUnshield: .init(
                supported: false,
                source: .untested,
                note: "PLAN.md risk 11: subtracting a single ApplicationToken from an active shield " +
                      "set is untested on macOS 13. Probe and update this entry on iMac 2017 hardware."
            ),
            .shieldWebDomains: .init(
                supported: true,
                source: .docVerified,
                note: "ManagedSettingsStore.shield.webDomains / webContent documented for macOS 13+"
            ),
            // account.lockAccounts and passcode.lockPasscode are iOS/iPadOS only.
            // The ManagedSettingsStore properties exist on macOS but are no-ops.
            .accountLock: .init(
                supported: false,
                source: .docVerified,
                note: "account.lockAccounts is iOS/iPadOS only per Apple documentation"
            ),
            .passcodeLock: .init(
                supported: false,
                source: .docVerified,
                note: "passcode.lockPasscode is iOS/iPadOS only per Apple documentation"
            ),
            // PLAN.md risk 9 — FamilyControls .child on macOS 13 unverified.
            .familyControlsChildAuth: .init(
                supported: false,
                source: .untested,
                note: "PLAN.md risk 9: .child authorization on macOS 13 with a Family Sharing child " +
                      "Apple ID is undocumented. Probe on iMac 2017 during onboarding. If unavailable, " +
                      "fall back to .individual (weaker tamper resistance)."
            ),
            // PLAN.md §Platform Notes — mitigated by KeepAlive LaunchAgent + 60s poll,
            // but callback reliability itself is not confirmed without hardware testing.
            .deviceActivityReliableAcrossSleep: .init(
                supported: false,
                source: .untested,
                note: "PLAN.md: DAM callbacks on macOS 13 may not fire after sleep/wake. " +
                      "Wake-nudge LaunchAgent is the mitigation. Probe on iMac 2017 to confirm."
            ),
        ]
        return CapabilityMatrix(platform: .macOS, osVersionMajor: osVersionMajor, table: table)
    }

    // MARK: iPadOS 16+
    static func iPadOS(osVersionMajor: Int) -> CapabilityMatrix {
        guard osVersionMajor >= 16 else {
            return CapabilityMatrix(platform: .iPadOS, osVersionMajor: osVersionMajor, table: [:])
        }
        let table: [ShieldCapability: CapabilityStatus] = [
            .shieldApplications: .init(supported: true, source: .docVerified),
            .shieldApplicationCategories: .init(supported: true, source: .docVerified),
            .shieldApplicationsPerTokenUnshield: .init(
                supported: true,
                source: .docVerified,
                note: "ManagedSettingsStore.shield.applications takes Set<ApplicationToken>; " +
                      "writes are atomic and partial sets are fully supported on iPadOS 16+"
            ),
            .shieldWebDomains: .init(supported: true, source: .docVerified),
            .accountLock: .init(supported: true, source: .docVerified),
            .passcodeLock: .init(supported: true, source: .docVerified),
            .familyControlsChildAuth: .init(supported: true, source: .docVerified),
            .deviceActivityReliableAcrossSleep: .init(
                supported: true,
                source: .docVerified,
                note: "iPadOS does not hibernate in the same way; DAM callbacks are reliable"
            ),
        ]
        return CapabilityMatrix(platform: .iPadOS, osVersionMajor: osVersionMajor, table: table)
    }

    // MARK: iOS 16+
    static func iOS(osVersionMajor: Int) -> CapabilityMatrix {
        guard osVersionMajor >= 16 else {
            return CapabilityMatrix(platform: .iOS, osVersionMajor: osVersionMajor, table: [:])
        }
        let table: [ShieldCapability: CapabilityStatus] = [
            .shieldApplications: .init(supported: true, source: .docVerified),
            .shieldApplicationCategories: .init(supported: true, source: .docVerified),
            .shieldApplicationsPerTokenUnshield: .init(supported: true, source: .docVerified),
            .shieldWebDomains: .init(supported: true, source: .docVerified),
            .accountLock: .init(supported: true, source: .docVerified),
            .passcodeLock: .init(supported: true, source: .docVerified),
            .familyControlsChildAuth: .init(supported: true, source: .docVerified),
            .deviceActivityReliableAcrossSleep: .init(supported: true, source: .docVerified),
        ]
        return CapabilityMatrix(platform: .iOS, osVersionMajor: osVersionMajor, table: table)
    }
}
