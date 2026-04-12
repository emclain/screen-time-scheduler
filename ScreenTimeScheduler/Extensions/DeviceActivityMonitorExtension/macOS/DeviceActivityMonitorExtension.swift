import DeviceActivity
import FamilyControls
import ManagedSettings
import os

private let logger = Logger(subsystem: "com.example.sts.DAMExtension", category: "dam")

private let appGroupSuite = "group.com.example.sts"
private let selectedAppsKey = "selectedApps"

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    private let store = ManagedSettingsStore()

    override func intervalDidStart(for activity: DeviceActivityName) {
        logger.info("dam_interval_start activity=\(activity.rawValue, privacy: .public) ts=\(Date.now.timeIntervalSince1970)")
        applyShields()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        logger.info("dam_interval_end activity=\(activity.rawValue, privacy: .public) ts=\(Date.now.timeIntervalSince1970)")
        clearShields()
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        logger.info("threshold_reached event=\(event.rawValue, privacy: .public) activity=\(activity.rawValue, privacy: .public) ts=\(Date.now.timeIntervalSince1970)")
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
}
