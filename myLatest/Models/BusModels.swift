//
//  BusModels.swift
//  myLatest
//
//  App-level models for displaying SEQ bus departure information.
//  Combines static GTFS schedule data with GTFS-RT real-time predictions.
//

import Foundation

// MARK: - Transport Mode

enum TransportMode: String, CaseIterable {
    case victorian   = "victorian"
    case queensland  = "queensland"

    var displayName: String {
        switch self {
        case .victorian:  return "Victorian Transport"
        case .queensland: return "Queensland Transport"
        }
    }
}

// MARK: - Bus Info (top-level model for BusCard)

struct BusInfo: Identifiable {
    let id = UUID()
    let nearbyStops: [NearbyBusStop]
    let favouriteStops: [NearbyBusStop]
    let alerts: [BusAlert]
    let brisbaneTimeAtFetch: String   // e.g. "2:22 PM"
    let locationAvailable: Bool
}

// MARK: - Nearby Bus Stop

struct NearbyBusStop: Identifiable {
    let id: String                    // stop_id
    let stopName: String
    let stopCode: String?
    let distanceMeters: Int
    let departures: [BusDeparture]
}

// MARK: - Bus Departure

struct BusDeparture: Identifiable {
    let id = UUID()
    let tripId: String
    let routeShortName: String        // e.g. "333"
    let routeLongName: String         // e.g. "Upper Mt Gravatt to City"
    let headsign: String?             // e.g. "Upper Mt Gravatt"
    let scheduledTime: String         // "2:22 PM" (Brisbane time)
    let scheduledSeconds: Int         // seconds since midnight
    let predictedTime: String?        // "2:24 PM" or nil if no RT data
    let delaySeconds: Int             // positive = late, negative = early
    let minutesAway: Int              // minutes until departure
    let status: BusDepartureStatus
    let stopSequence: Int
}

enum BusDepartureStatus: String {
    case onTime  = "On Time"
    case early   = "Early"
    case late    = "Late"
    case noData  = "Scheduled"
    case skipped = "Not Stopping"

    var color: String {
        switch self {
        case .onTime:  return "green"
        case .early:   return "blue"
        case .late:    return "orange"
        case .noData:  return "secondary"
        case .skipped: return "red"
        }
    }
}

// MARK: - Bus Alert

struct BusAlert: Identifiable {
    let id = UUID()
    let headerText: String
    let descriptionText: String?
    let severity: BusAlertSeverity
    let effect: String
    let affectedRoutes: [String]      // route_ids affected
    let affectedStops: [String]       // stop_ids affected
}

enum BusAlertSeverity: String {
    case info    = "info"
    case warning = "warning"
    case severe  = "severe"

    var symbolName: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .severe:  return "xmark.octagon.fill"
        }
    }
}

// MARK: - Mock data

extension BusInfo {
    static func placeholder() -> BusInfo {
        let now = Date()
        let brisbane = TimeZone(identifier: "Australia/Brisbane")!
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = brisbane

        return BusInfo(
            nearbyStops: [
                NearbyBusStop(
                    id: "placeholder-1",
                    stopName: "Nearby bus stop",
                    stopCode: "000",
                    distanceMeters: 120,
                    departures: (0..<3).map { i in
                        BusDeparture(
                            tripId: "mock-\(i)",
                            routeShortName: "---",
                            routeLongName: "Loading route name",
                            headsign: "Loading...",
                            scheduledTime: formatter.string(from: now.addingTimeInterval(Double(i * 600))),
                            scheduledSeconds: 0,
                            predictedTime: nil,
                            delaySeconds: 0,
                            minutesAway: i * 10 + 5,
                            status: .noData,
                            stopSequence: 0
                        )
                    }
                )
            ],
            favouriteStops: [],
            alerts: [],
            brisbaneTimeAtFetch: "--:-- --",
            locationAvailable: true
        )
    }

    static func noLocation() -> BusInfo {
        BusInfo(
            nearbyStops: [],
            favouriteStops: [],
            alerts: [],
            brisbaneTimeAtFetch: "--:-- --",
            locationAvailable: false
        )
    }
}
