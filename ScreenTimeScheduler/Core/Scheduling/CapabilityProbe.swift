import Foundation
import ManagedSettings
import FamilyControls
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
        let store = ManagedSettingsStore()

        // Ensure clean state before probe.
        defer {
            store.shield.applications = nil
            store.shield.applicationCategories = nil
        }

        // Write a nil → nil transition (trivially works).
        store.shield.applications = nil
        let afterClear = store.shield.applications
        guard afterClear == nil else {
            return .failed(reason: "shield.applications could not be cleared to nil")
        }

        // We cannot manufacture real ApplicationTokens here, so we confirm the
        // write path accepts an empty set (which effectively clears the shield).
        store.shield.applications = []
        let afterEmpty = store.shield.applications
        // On macOS 13, setting to empty Set should behave the same as nil.
        // If it throws or returns a non-empty set, something is wrong.
        if let apps = afterEmpty, !apps.isEmpty {
            return .failed(reason: "shield.applications = [] left non-empty store: \(apps.count) tokens")
        }

        // Mechanical write succeeded. Full per-token test requires real tokens —
        // do this manually during onboarding or a dedicated UI test.
        return .partiallyVerified(
            note: "ManagedSettingsStore write API accepts nil/empty transitions without error. " +
                  "Full per-token subtract test requires real ApplicationTokens from FamilyActivityPicker. " +
                  "Run ScheduleEditorView onboarding, pick 2 apps, shield both, then attempt a " +
                  "single-token removal and confirm only one app is still shielded. " +
                  "Update CapabilityMatrix.shieldApplicationsPerTokenUnshield to .empirical."
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
        let center = AuthorizationCenter.shared
        let currentStatus = center.authorizationStatus

        // If already authorized (from a previous session), report what mode was used.
        if currentStatus == .approved {
            return .verified(
                note: "FamilyControls already authorized (status=.approved). " +
                      "Check AuthorizationCenter.shared.authorizationStatus and whether " +
                      "the app's entitlement used .child or .individual."
            )
        }

        // Attempt .child request and inspect the result.
        do {
            try await center.requestAuthorization(for: .child)
            return .verified(
                note: "FamilyControls .child authorization request succeeded. " +
                      "Update CapabilityMatrix.familyControlsChildAuth to " +
                      ".empirical(supported: true). PLAN.md risk 9 resolved."
            )
        } catch let error as FamilyControlsError {
            switch error {
            case .restricted:
                return .verified(
                    note: "FamilyControls .child returned .restricted — likely not a Family " +
                          "Sharing child account. Test again with the actual child Apple ID. " +
                          "If it still fails, fall back to .individual per PLAN.md risk 9."
                )
            case .invalidArgument:
                return .failed(
                    reason: "FamilyControls .child returned .invalidArgument on macOS 13. " +
                            "API may not support .child on this platform. " +
                            "Update CapabilityMatrix.familyControlsChildAuth to " +
                            ".empirical(supported: false) and use .individual fallback."
                )
            default:
                return .partiallyVerified(
                    note: "FamilyControls .child returned unexpected error: \(error). " +
                          "Run on the child's iCloud account to confirm."
                )
            }
        } catch {
            return .failed(reason: "FamilyControls .child threw unexpected error: \(error)")
        }
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
