//
//  DrivingDestinationStore.swift
//  myLatest
//

import Foundation
import Observation

@Observable
final class DrivingDestinationStore {
    static let shared = DrivingDestinationStore()

    private(set) var custom: [DrivingDestination] = []
    var all: [DrivingDestination] { custom }

    private let storageKey = "myLatest.customDrivingDestinations"

    private init() {
        load()
    }

    func add(_ destination: DrivingDestination) {
        custom.append(destination)
        persist()
    }

    func delete(offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            custom.remove(at: index)
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let destinations = try? JSONDecoder().decode([DrivingDestination].self, from: data)
        else { return }

        custom = destinations
    }
}
