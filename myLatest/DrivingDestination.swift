//
//  DrivingDestination.swift
//  myLatest
//

import CoreLocation
import Foundation

struct DrivingDestination: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    var title: String?

    init(id: UUID = UUID(),
         name: String,
         address: String,
         latitude: Double,
         longitude: Double,
         title: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.title = title
    }

    /// Returns the user-provided title if set, otherwise the resolved name.
    var displayName: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return name
    }

    /// Returns the subtitle to show beneath the display name.
    /// If a custom title is set, shows the address; otherwise shows the address too.
    var displaySubtitle: String {
        address
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Returns a copy with the given title applied.
    func withTitle(_ title: String) -> DrivingDestination {
        var copy = self
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = trimmed.isEmpty ? nil : trimmed
        return copy
    }
}
