import DeviceActivity
import os

/// Registers the hardcoded blocking schedule with DeviceActivityCenter.
///
/// Call `ScheduleManager.shared.register()` once at app launch.  The call
/// is idempotent: re-registering an already-active schedule is a no-op from
/// DAM's perspective and is safe to call on every launch.
final class ScheduleManager {
    static let shared = ScheduleManager()
    private init() {}

    func register() {
        #if os(iOS)
        let window = Window.hardcoded
        let schedule = DeviceActivitySchedule(
            intervalStart: window.start,
            intervalEnd: window.end,
            repeats: true
        )
        do {
            try DeviceActivityCenter().startMonitoring(
                .hardcodedWindow,
                during: schedule
            )
            logInfo(Logger.dam,
                    "\(LogEvent.damIntervalStart): registered hardcoded schedule " +
                    "09:00-17:00 Mon-Fri activity=\(DeviceActivityName.hardcodedWindow.rawValue)")
        } catch {
            logError(Logger.dam,
                     "schedule registration failed activity=\(DeviceActivityName.hardcodedWindow.rawValue) " +
                     "error=\(error)")
        }
        #endif
    }
}
