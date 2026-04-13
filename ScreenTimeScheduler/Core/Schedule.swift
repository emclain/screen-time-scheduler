import DeviceActivity
import Foundation

// MARK: - Window

/// A single daily blocking window: a time range that repeats on selected weekdays.
struct Window {
    /// Gregorian weekday numbers: 1 = Sunday, 2 = Monday … 7 = Saturday.
    let weekdays: [Int]
    let start: DateComponents
    let end: DateComponents
}

// MARK: - Milestone 1 hardcoded schedule

extension Window {
    /// Block picked apps 09:00–17:00, Monday–Friday.
    static let hardcoded = Window(
        weekdays: [2, 3, 4, 5, 6],
        start: DateComponents(hour: 9, minute: 0),
        end: DateComponents(hour: 17, minute: 0)
    )
}

// MARK: - DeviceActivity names

#if os(iOS)
extension DeviceActivityName {
    static let hardcodedWindow = DeviceActivityName("com.example.sts.window.hardcoded")
}
#endif
