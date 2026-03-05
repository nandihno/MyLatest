//
//  myLatestApp.swift
//  myLatest
//

import SwiftUI

@main
struct myLatestApp: App {
    /// Held at app level so the @Observable store is created once and lives for
    /// the full session.  Injected into the SwiftUI environment so any view can
    /// read it with @Environment(WeatherStationStore.self).
    @State private var stationStore = WeatherStationStore.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Today", systemImage: "rectangle.grid.1x2.fill") {
                    ContentView()
                        .environment(stationStore)
                }
                Tab("Health", systemImage: "heart.fill") {
                    HealthView()
                }
            }
        }
    }
}
