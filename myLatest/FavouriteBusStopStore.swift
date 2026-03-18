//
//  FavouriteBusStopStore.swift
//  myLatest
//
//  Persists user's favourite bus stops so they always appear
//  in the bus departure card regardless of proximity.
//

import Foundation
import Observation

struct FavouriteBusStop: Codable, Identifiable {
    let stopId: String
    let stopName: String
    let stopCode: String?
    let latitude: Double
    let longitude: Double

    var id: String { stopId }
}

@Observable
final class FavouriteBusStopStore {
    static let shared = FavouriteBusStopStore()

    private(set) var all: [FavouriteBusStop] = []

    private let storageKey = "myLatest.favouriteBusStops"

    private init() {
        load()
    }

    func add(_ stop: FavouriteBusStop) {
        guard !all.contains(where: { $0.stopId == stop.stopId }) else { return }
        all.append(stop)
        persist()
    }

    func remove(stopId: String) {
        all.removeAll { $0.stopId == stopId }
        persist()
    }

    func delete(offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            all.remove(at: index)
        }
        persist()
    }

    func contains(stopId: String) -> Bool {
        all.contains { $0.stopId == stopId }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let stops = try? JSONDecoder().decode([FavouriteBusStop].self, from: data)
        else { return }
        all = stops
    }
}
