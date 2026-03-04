//
//  Models.swift
//  myLatest
//

import Foundation

// MARK: - Weather

/// A single 30-minute observation from the BOM station.
struct WeatherObservation: Identifiable {
    let id = UUID()
    let localDateTime: String   // e.g. "11:30am"
    let apparentTemp: Double    // apparent_t  – feels-like temperature (°C)
    let airTemp: Double         // air_temp    – actual temperature (°C)
    let relHumidity: Int        // rel_hum     – relative humidity (%)
    let cloud: String           // "Sunny" when BOM field is empty/"-"
    let windDir: String         // e.g. "SW"
    let windSpeedKmh: Int       // wind_spd_kmh

    /// SF Symbol that best represents the cloud condition string.
    var symbolName: String {
        let c = cloud.lowercased()
        if c == "sunny" || c == "clear" || c.hasPrefix("fine") { return "sun.max.fill" }
        if c.contains("shower") || c.contains("rain")          { return "cloud.rain.fill" }
        if c.contains("storm") || c.contains("thunder")        { return "cloud.bolt.rain.fill" }
        if c.contains("partly")                                 { return "cloud.sun.fill" }
        if c.contains("fog") || c.contains("mist")             { return "cloud.fog.fill" }
        return "cloud.fill"
    }
}

/// Aggregates up to 5 observations from the nearest BOM weather station.
struct WeatherInfo: Identifiable {
    let id = UUID()
    let stationName: String
    let observations: [WeatherObservation]  // most-recent first, up to 5

    var latest: WeatherObservation? { observations.first }
}

// MARK: - Calendar

struct CalendarEvent: Identifiable {
    let id = UUID()
    let title: String
    let date: Date
    let durationMinutes: Int
    let location: String?
    let isAllDay: Bool
    /// EKEvent.eventIdentifier — nil for mock/placeholder events.
    let eventIdentifier: String?

    // Convenience init for mock data (no identifier needed)
    init(title: String, date: Date, durationMinutes: Int,
         location: String?, isAllDay: Bool, eventIdentifier: String? = nil) {
        self.title           = title
        self.date            = date
        self.durationMinutes = durationMinutes
        self.location        = location
        self.isAllDay        = isAllDay
        self.eventIdentifier = eventIdentifier
    }
}

// MARK: - Train

/// Top-level model passed to TrainCard.
struct TrainInfo: Identifiable {
    let id = UUID()
    let lineName: String

    // Service status
    let serviceIsGood: Bool             // true when alerts is a "Good service" string
    let serviceStatusMessage: String    // the good-service message or first alert summary

    // Live alerts (empty when serviceIsGood == true)
    let alerts: [TrainServiceAlert]

    // Planned works list
    let plannedWorks: [TrainPlannedWork]

    // Departures
    let homeStationName: String
    let cityStationName: String
    let homeStationDepartures: [TrainDeparture]
    let cityStationDepartures: [TrainDeparture]

    /// Melbourne local time at the moment data was fetched (e.g. "8:45 AM").
    let melbourneTimeAtFetch: String
}

/// A single live service disruption alert for a line.
struct TrainServiceAlert: Identifiable {
    let id: String                          // alert_id from API
    let alertType: String                   // "works" | "minor" | "major"
    let plainText: String                   // HTML stripped
    let additionalTravelMinutes: Int?
    let disruptionDueTo: String?
}

/// An entry from planned_works_list.
struct TrainPlannedWork: Identifiable {
    let id: Int
    let title: String
    let link: String
    let type: String
    let upcomingCurrent: String             // "Current" | "Upcoming"
    let affectedStations: [String]
}

/// A single upcoming departure at a station.
struct TrainDeparture: Identifiable {
    let id = UUID()
    let station: String
    let isToCity: Bool                      // true = inbound (to_city == "1")
    let scheduledTimeStr: String            // time_str (scheduled)
    let estimatedArrivalStr: String         // estimated_arrival_time_str
    let estimatedDepartureStr: String       // estimated_departure_time_str
    let estimatedDepartureSeconds: Int      // for sorting / filtering
    let platform: String                    // scheduled platform
    let estimatedPlatform: String           // real-time platform (preferred)
}

// MARK: - Dashboard

struct DashboardData {
    let weather: WeatherInfo
    let upcomingEvents: [CalendarEvent]
    let trainInfo: TrainInfo
    let fetchedAt: Date
}
