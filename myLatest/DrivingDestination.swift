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

    init(id: UUID = UUID(),
         name: String,
         address: String,
         latitude: Double,
         longitude: Double) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
