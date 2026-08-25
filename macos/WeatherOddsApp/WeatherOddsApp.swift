import SwiftUI
import WidgetKit

@main
struct WeatherOddsApp: App {
    init() {
        #if DEBUG
        WidgetCenter.shared.reloadTimelines(ofKind: "com.polarsky.weatherodds.forecast")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 560, height: 420)
        .windowResizability(.contentSize)
    }
}
