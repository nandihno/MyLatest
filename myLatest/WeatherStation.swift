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

    /// Bundled starter stations loaded from `stations.json`.
    static let defaults: [WeatherStation] = loadDefaults()

    private static func loadDefaults(bundle: Bundle = .main) -> [WeatherStation] {
        guard
            let url = bundle.url(forResource: "stations", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let seeds = try? JSONDecoder().decode([BundledWeatherStation].self, from: data)
        else {
            assertionFailure("Unable to load bundled stations.json")
            return []
        }

        return seeds.map {
            WeatherStation(state: $0.state, title: $0.title, url: $0.url, lat: $0.lat, lon: $0.lon)
        }
    }

    // MARK: - Nearest finder

    /// Returns the station closest to the given device location from the supplied list.
    static func nearest(to location: CLLocation, from stations: [WeatherStation]) -> WeatherStation? {
        stations.min { $0.distance(to: location) < $1.distance(to: location) }
    }
}

private struct BundledWeatherStation: Decodable {
    let state: String
    let title: String
    let url: String
    let lat: Double
    let lon: Double
}
