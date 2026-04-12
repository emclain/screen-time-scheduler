import DeviceActivity
import FamilyControls
import ManagedSettings
import os

private let logger = Logger(subsystem: "com.example.sts", category: "dam")

private let appGroupSuite = "group.com.example.sts"
private let selectedAppsKey = "selectedApps"

// Keys for missed-callback detection via persistent sequence counters.
// intervalDidStart and intervalDidEnd should alternate; a gap in either
// counter indicates a missed callback.  Read with:
//   log show --predicate 'subsystem == "com.example.sts" AND category == "dam"'
// or inspect the UserDefaults suite directly to compare counts post-test.
private let damStartSeqKey = "dam_start_seq"
private let damEndSeqKey = "dam_end_seq"

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    private let store = ManagedSettingsStore()

    override func intervalDidStart(for activity: DeviceActivityName) {
        let seq = incrementSeq(key: damStartSeqKey)
        let endSeq = currentSeq(key: damEndSeqKey)
        // If start count exceeds end count by more than 1, a previous
        // intervalDidEnd was missed (e.g., during sleep/wake).
        let skipped = seq - endSeq - 1
        if skipped > 0 {
            logger.warning("dam_missed_callback kind=end activity=\(activity.rawValue, privacy: .public) skipped=\(skipped) start_seq=\(seq) end_seq=\(endSeq)")
        }
        logger.info("dam_interval_start activity=\(activity.rawValue, privacy: .public) seq=\(seq) ts=\(isoNow())")
        applyShields()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        let seq = incrementSeq(key: damEndSeqKey)
        let startSeq = currentSeq(key: damStartSeqKey)
        // If end count exceeds start count, a previous intervalDidStart was missed.
        let skipped = seq - startSeq
        if skipped > 0 {
            logger.warning("dam_missed_callback kind=start activity=\(activity.rawValue, privacy: .public) skipped=\(skipped) start_seq=\(startSeq) end_seq=\(seq)")
        }
        logger.info("dam_interval_end activity=\(activity.rawValue, privacy: .public) seq=\(seq) ts=\(isoNow())")
        clearShields()
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        logger.info("threshold_reached event=\(event.rawValue, privacy: .public) activity=\(activity.rawValue, privacy: .public) ts=\(isoNow())")
    }

    // MARK: - Shield apply/clear

    private func applyShields() {
        let tokens = loadTokens()
        store.shield.applications = tokens.isEmpty ? nil : tokens
        logger.info("shield_applied count=\(tokens.count)")
    }

    private func clearShields() {
        store.shield.applications = nil
        logger.info("shield_cleared")
    }

    private func loadTokens() -> Set<ApplicationToken> {
        guard let defaults = UserDefaults(suiteName: appGroupSuite),
              let data = defaults.data(forKey: selectedAppsKey),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else {
            logger.warning("token_load_failed app_group=\(appGroupSuite, privacy: .public)")
            return []
        }
        return selection.applicationTokens
    }

    // MARK: - Sequence counter helpers

    private func incrementSeq(key: String) -> Int {
        guard let defaults = UserDefaults(suiteName: appGroupSuite) else { return 0 }
        let next = defaults.integer(forKey: key) + 1
        defaults.set(next, forKey: key)
        return next
    }

    private func currentSeq(key: String) -> Int {
        UserDefaults(suiteName: appGroupSuite)?.integer(forKey: key) ?? 0
    }
}

// MARK: - Timestamp helpers

private func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}
