//
//  WeatherStationStore.swift
//  myLatest
//
//  Single source of truth for all weather stations.
//  Built-in stations live in WeatherStation.defaults (code).
//  Custom stations are persisted to UserDefaults as JSON.
//

import Foundation
import Observation
import SwiftUI

@Observable
final class WeatherStationStore {

    // MARK: - Singleton

    static let shared = WeatherStationStore()

    // MARK: - State

    /// User-added stations (persisted).
    private(set) var custom: [WeatherStation] = []

    /// All stations available for nearest-station lookup.
    var all: [WeatherStation] { WeatherStation.defaults + custom }

    // MARK: - Persistence

    private let storageKey = "myLatest.customWeatherStations"

    private init() {
        load()
    }

    // MARK: - Mutation

    func add(_ station: WeatherStation) {
        custom.append(station)
        persist()
    }

    func delete(offsets: IndexSet) {
        custom.remove(atOffsets: offsets)
        persist()
    }

    // MARK: - Private helpers

    private func persist() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard
            let data     = UserDefaults.standard.data(forKey: storageKey),
            let stations = try? JSONDecoder().decode([WeatherStation].self, from: data)
        else { return }
        custom = stations
    }
}
