import DeviceActivity
import os

private let logger = Logger(subsystem: "com.example.sts.DAMExtension", category: "monitor")

class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        logger.info("intervalDidStart: \(activity.rawValue)")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        logger.info("intervalDidEnd: \(activity.rawValue)")
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        logger.info("threshold reached: \(event.rawValue) activity: \(activity.rawValue)")
    }
}
