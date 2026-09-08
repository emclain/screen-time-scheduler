import SwiftUI
import FamilyControls

@main
struct ScreenTimeSchedulerApp: App {
    init() {
        ScheduleManager.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
