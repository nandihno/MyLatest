//
//  WeatherStation.swift
//  myLatest
//

import Foundation
import CoreLocation

// MARK: - Australian States

enum AustralianState: String, CaseIterable, Codable, Identifiable {
    case vic = "VIC"
    case nsw = "NSW"
    case qld = "QLD"
    case act = "ACT"
    case wa  = "WA"
    case sa  = "SA"
    case tas = "TAS"
    case nt  = "NT"

    var id: String { rawValue }

    var fullName: String {
        switch self {
        case .vic: return "Victoria"
        case .nsw: return "New South Wales"
        case .qld: return "Queensland"
        case .act: return "Australian Capital Territory"
        case .wa:  return "Western Australia"
        case .sa:  return "South Australia"
        case .tas: return "Tasmania"
        case .nt:  return "Northern Territory"
        }
    }
}

// MARK: - Weather Station

struct WeatherStation: Identifiable, Codable {
    let id: UUID
    let state: String
    let title: String
    let url: String
    let lat: Double
    let lon: Double

    /// Convenience init that auto-generates an ID (used for custom stations and built-ins).
    init(state: String, title: String, url: String, lat: Double, lon: Double) {
        self.id    = UUID()
        self.state = state
        self.title = title
        self.url   = url
        self.lat   = lat
        self.lon   = lon
    }

    func distance(to location: CLLocation) -> CLLocationDistance {
        CLLocation(latitude: lat, longitude: lon).distance(from: location)
    }

    // MARK: - Built-in station catalogue

    /// The hardcoded starter set.  Custom stations live in WeatherStationStore.
    static let defaults: [WeatherStation] = [
        WeatherStation(state: "VIC", title: "Point Cook",
                       url: "https://www.bom.gov.au/fwo/IDV60901/IDV60901.95941.json",
                       lat: -37.9, lon: 144.8),
        WeatherStation(state: "VIC", title: "Melbourne",
                       url: "https://www.bom.gov.au/fwo/IDV60901/IDV60901.95936.json",
                       lat: -37.8, lon: 145.0),
        WeatherStation(state: "VIC", title: "Moorabin Airport",
                       url: "https://www.bom.gov.au/fwo/IDV60901/IDV60901.94870.json",
                       lat: -38.0, lon: 145.1),
        WeatherStation(state: "VIC", title: "Laverton",
                       url: "https://www.bom.gov.au/fwo/IDV60901/IDV60901.94865.json",
                       lat: -37.9, lon: 144.8),
        WeatherStation(state: "QLD", title: "Brisbane",
                       url: "https://www.bom.gov.au/fwo/IDQ60901/IDQ60901.94576.json",
                       lat: -27.5, lon: 153.0),
    ]

    // MARK: - Nearest finder

    /// Returns the station closest to the given device location from the supplied list.
    static func nearest(to location: CLLocation, from stations: [WeatherStation]) -> WeatherStation? {
        stations.min { $0.distance(to: location) < $1.distance(to: location) }
    }
}
