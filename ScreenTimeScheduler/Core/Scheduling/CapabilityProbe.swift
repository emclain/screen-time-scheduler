import Foundation
import os

// CapabilityProbe — runtime diagnostic for macOS 13 Ventura hardware.
//
// Run this once on the iMac 2017 (in a Development-signed build) to populate the
// .untested entries in CapabilityMatrix. Log output is written to the app's
// ubiquity container log file so it survives past the console session.
//
// Probes performed:
//   1. shieldApplicationsPerTokenUnshield  (PLAN.md risk 11)
//   2. familyControlsChildAuth             (PLAN.md risk 9)
//   3. deviceActivityReliableAcrossSleep   (PLAN.md §Platform Notes)
//      — This one cannot be probed programmatically; it requires a manual
//        sleep/wake cycle and observation. The probe logs a reminder instead.
//
// After running, update CapabilityMatrix.macOS() with .empirical status
// and the observed result. Keep this file for future reinstalls.

#if os(macOS)

/// Capabilities under empirical test by CapabilityProbe.
///
/// These map to the `.unknown` entries in `CapabilityMatrix.macOS13Support()`.
/// Once each probe completes, update the corresponding `Capability` entry in
/// `CapabilityMatrix` to reflect the observed result.
public enum ShieldCapability: String, CaseIterable, Hashable, Sendable {
    /// Atomically removing a single ApplicationToken from an active shield without
    /// clearing the whole store. Required for app-scoped grant overrides (PLAN.md risk 11).
    case shieldApplicationsPerTokenUnshield
    /// FamilyControls `.child` authorization on macOS 13 (PLAN.md risk 9).
    case familyControlsChildAuth
    /// DeviceActivityMonitor callbacks fire reliably after sleep/wake (PLAN.md §Platform Notes).
    /// Cannot be probed programmatically; requires a manual sleep/wake cycle.
    case deviceActivityReliableAcrossSleep
}

public actor CapabilityProbe {

    private let log: Logger

    public init(log: Logger) {
        self.log = log
    }

    /// Run all automated probes and return a summary. Must be called from the
    /// main app (not an extension) so ManagedSettingsStore writes are allowed.
    public func runAll() async -> ProbeReport {
        var results: [ShieldCapability: ProbeResult] = [:]

        results[.shieldApplicationsPerTokenUnshield] = await probePerTokenUnshield()
        results[.familyControlsChildAuth] = await probeFamilyControlsChildAuth()
        results[.deviceActivityReliableAcrossSleep] = .manualRequired(
            instruction: "Sleep the iMac (Apple menu → Sleep), wait 60s, wake it, then check " +
                         "whether a DeviceActivityMonitor intervalDidStart fires within 2 minutes. " +
                         "Expected: no — the wake-nudge LaunchAgent is the mitigation. " +
                         "Update CapabilityMatrix.deviceActivityReliableAcrossSleep accordingly."
        )

        let report = ProbeReport(platform: "macOS", osVersionMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, results: results)
        log.info("CapabilityProbe complete:\n\(report.summary)")
        return report
    }

    // MARK: - Probe 1: Per-token unshield (PLAN.md risk 11)
    //
    // Strategy: shield two synthetic-ish stores (we can't use real tokens here
    // without FamilyActivityPicker, but we can verify the mechanics of writing a
    // non-nil then narrowed shield without crashing or silently failing).
    //
    // A full empirical test requires real ApplicationTokens selected via
    // FamilyActivityPicker during onboarding; this probe only checks that the
    // ManagedSettingsStore write API accepts an update to a smaller set without
    // throwing — it does not verify enforcement in the UI.
    private func probePerTokenUnshield() async -> ProbeResult {
        // ManagedSettingsStore is @available(macOS, unavailable) in the Xcode 16 SDK —
        // these types exist only for iOS/Mac Catalyst. The probe cannot run on native macOS.
        return .failed(
            reason: "ManagedSettingsStore is unavailable on native macOS (Xcode 16 SDK). " +
                    "Run this probe on the iOS target to verify per-token unshield behaviour."
        )
    }

    // MARK: - Probe 2: FamilyControls .child authorization (PLAN.md risk 9)
    //
    // Attempts to request .child authorization. If the signed-in iCloud account
    // is a Family Sharing child, this should succeed (requiring parent approval).
    // If the account is not a child, it will fail with a known error code.
    // Either way, the error domain/code reveals whether the API path exists on
    // macOS 13 for this account type.
    private func probeFamilyControlsChildAuth() async -> ProbeResult {
        // AuthorizationCenter is @available(macOS, unavailable) in the Xcode 16 SDK —
        // FamilyControls authorization APIs are iOS/Mac Catalyst only. Cannot probe on native macOS.
        return .failed(
            reason: "AuthorizationCenter is unavailable on native macOS (Xcode 16 SDK). " +
                    "Run this probe on the iOS target to verify FamilyControls .child authorization."
        )
    }
}

// MARK: - Report types

public struct ProbeReport: Sendable {
    public let platform: String
    public let osVersionMajor: Int
    public let results: [ShieldCapability: ProbeResult]

    public var summary: String {
        var lines = ["CapabilityProbe — \(platform) \(osVersionMajor)"]
        for cap in ShieldCapability.allCases {
            let result = results[cap] ?? .notRun
            lines.append("  \(cap.rawValue): \(result.label)")
            if let detail = result.detail {
                lines.append("    → \(detail)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum ProbeResult: Sendable {
    case verified(note: String? = nil)
    case partiallyVerified(note: String)
    case failed(reason: String)
    case manualRequired(instruction: String)
    case notRun

    var label: String {
        switch self {
        case .verified: return "✓ verified"
        case .partiallyVerified: return "~ partial"
        case .failed: return "✗ failed"
        case .manualRequired: return "⚠ manual required"
        case .notRun: return "— not run"
        }
    }

    var detail: String? {
        switch self {
        case .verified(let note): return note
        case .partiallyVerified(let note): return note
        case .failed(let reason): return reason
        case .manualRequired(let instruction): return instruction
        case .notRun: return nil
        }
    }
}

#endif
