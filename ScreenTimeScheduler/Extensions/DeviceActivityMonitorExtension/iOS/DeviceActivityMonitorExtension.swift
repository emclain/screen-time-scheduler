import DeviceActivity
import os

private let logger = Logger(subsystem: "com.example.sts.DAMExtension", category: "dam")

class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        logger.info("dam_interval_start activity=\(activity.rawValue, privacy: .public) ts=\(Date.now.timeIntervalSince1970)")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        logger.info("dam_interval_end activity=\(activity.rawValue, privacy: .public) ts=\(Date.now.timeIntervalSince1970)")
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        logger.info("threshold_reached event=\(event.rawValue, privacy: .public) activity=\(activity.rawValue, privacy: .public) ts=\(Date.now.timeIntervalSince1970)")
    }
}
