//
//  MockDataService.swift
//  myLatest
//
//  Orchestrates the full dashboard fetch:
//    • Weather  → WeatherService   (real BOM data,       falls back to mock on any error)
//    • Calendar → CalendarService  (real EventKit data,  falls back to mock on any error)
//    • Train    → TrainService     (real Metro Trains,   falls back to mock on any error)
//

import Foundation

final class MockDataService {
    static let shared = MockDataService()
    private init() {}

    private func rethrowIfCancelled(_ error: Error) throws {
        if error is CancellationError {
            throw CancellationError()
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == URLError.cancelled.rawValue {
            throw CancellationError()
        }
    }

    // MARK: - Public API

    func fetchDashboard(trainLineName: String,
                        homeStation: String,
                        cityStation: String,
                        drivingProvider: DrivingProvider = .apple,
                        googleMapsApiKey: String = "",
                        includeWeather: Bool = true) async throws -> DashboardData {
        // Calendar and train sources always run concurrently.
        async let eventsTask  = fetchCalendarEventsSafely()
        async let trainTask   = fetchTrainInfoSafely(lineName:      trainLineName,
                                                     homeStation:   homeStation,
                                                     cityStation:   cityStation)
        async let drivingTask = fetchDrivingTimesSafely(provider: drivingProvider, googleApiKey: googleMapsApiKey)

        // Weather can be skipped by tabs that do not render weather content.
        let weather: WeatherInfo
        if includeWeather {
            weather = try await fetchWeatherSafely()
        } else {
            weather = Self.mockWeather()
        }

        let events = try await eventsTask
        let train = try await trainTask
        let driving = await drivingTask

        return DashboardData(
            weather:        weather,
            upcomingEvents: events,
            trainInfo:      train,
            drivingEstimates: driving,
            fetchedAt:      Date()
        )
    }

    // MARK: - Weather (real with mock fallback)

    private func fetchWeatherSafely() async throws -> WeatherInfo {
        do {
            return try await WeatherService.shared.fetchWeather()
        } catch {
            try rethrowIfCancelled(error)
            print("⚠️ WeatherService failed (\(error.localizedDescription)) — using mock data.")
            return Self.mockWeather()
        }
    }

    // MARK: - Calendar (real EventKit with mock fallback)

    private func fetchCalendarEventsSafely() async throws -> [CalendarEvent] {
        do {
            return try await CalendarService.shared.fetchUpcomingEvents()
        } catch {
            try rethrowIfCancelled(error)
            print("⚠️ CalendarService failed (\(error.localizedDescription)) — using mock data.")
            return Self.mockEvents()
        }
    }

    // MARK: - Train (real Metro Trains with mock fallback)

    private func fetchTrainInfoSafely(lineName: String,
                                      homeStation: String,
                                      cityStation: String) async throws -> TrainInfo {
        guard !lineName.isEmpty else {
            return Self.mockTrainInfo(lineName: lineName,
                                      homeStation: homeStation,
                                      cityStation: cityStation)
        }
        do {
            return try await TrainService.shared.fetchTrainInfo(lineName:     lineName,
                                                                homeStation:  homeStation,
                                                                cityStation:  cityStation)
        } catch {
            try rethrowIfCancelled(error)
            print("⚠️ TrainService failed — using mock data.\n   \(error)")
            return Self.mockTrainInfo(lineName: lineName,
                                      homeStation: homeStation,
                                      cityStation: cityStation)
        }
    }

    // MARK: - Driving times

    private func fetchDrivingTimesSafely(provider: DrivingProvider, googleApiKey: String) async -> [DrivingTimeEstimate] {
        let destinations = DrivingDestinationStore.shared.all
        guard !destinations.isEmpty else { return [] }

        do {
            return try await DrivingTimeService.shared.fetchDrivingTimes(provider: provider, googleApiKey: googleApiKey)
        } catch {
            print("⚠️ DrivingTimeService failed (\(error.localizedDescription)) — returning unavailable routes.")
            return destinations.map {
                DrivingTimeEstimate.unavailable(destination: $0, message: error.localizedDescription)
            }
        }
    }

    // MARK: - Mock builders (static so previews can use them directly)

    static func mockWeather() -> WeatherInfo {
        WeatherInfo(
            stationName: "Laverton",
            observations: [
                WeatherObservation(localDateTime: "11:30am", apparentTemp: 17.4, airTemp: 18.8,
                                   pressureMSL: 1011.7, relHumidity: 81, cloud: "Cloudy",        windDir: "SW", windSpeedKmh: 17),
                WeatherObservation(localDateTime: "11:00am", apparentTemp: 16.8, airTemp: 17.9,
                                   pressureMSL: 1011.9, relHumidity: 83, cloud: "Cloudy",        windDir: "SW", windSpeedKmh: 19),
                WeatherObservation(localDateTime: "10:30am", apparentTemp: 15.9, airTemp: 17.1,
                                   pressureMSL: 1012.1, relHumidity: 85, cloud: "Mostly Cloudy", windDir: "SW", windSpeedKmh: 15),
                WeatherObservation(localDateTime: "10:00am", apparentTemp: 15.2, airTemp: 16.4,
                                   pressureMSL: 1012.4, relHumidity: 86, cloud: "Mostly Cloudy", windDir: "S",  windSpeedKmh: 13),
                WeatherObservation(localDateTime:  "9:30am", apparentTemp: 14.6, airTemp: 15.7,
                                   pressureMSL: 1012.7, relHumidity: 88, cloud: "Overcast",      windDir: "S",  windSpeedKmh: 11),
                WeatherObservation(localDateTime:  "9:00am", apparentTemp: 14.1, airTemp: 15.2,
                                   pressureMSL: 1012.9, relHumidity: 89, cloud: "Overcast",      windDir: "S",  windSpeedKmh: 10),
                WeatherObservation(localDateTime:  "8:30am", apparentTemp: 13.8, airTemp: 14.9,
                                   pressureMSL: 1013.2, relHumidity: 90, cloud: "Overcast",      windDir: "SE", windSpeedKmh:  9),
                WeatherObservation(localDateTime:  "8:00am", apparentTemp: 13.2, airTemp: 14.2,
                                   pressureMSL: 1013.4, relHumidity: 91, cloud: "Cloudy",        windDir: "SE", windSpeedKmh:  8),
                WeatherObservation(localDateTime:  "7:30am", apparentTemp: 12.7, airTemp: 13.7,
                                   pressureMSL: 1013.6, relHumidity: 92, cloud: "Cloudy",        windDir: "E",  windSpeedKmh:  8),
                WeatherObservation(localDateTime:  "7:00am", apparentTemp: 12.1, airTemp: 13.0,
                                   pressureMSL: 1013.8, relHumidity: 93, cloud: "Cloudy",        windDir: "E",  windSpeedKmh:  7),
            ]
        )
    }

    static func mockEvents() -> [CalendarEvent] {
        let now = Date()
        let cal = Calendar.current
        return [
            CalendarEvent(title: "Team Standup",
                          date: cal.date(byAdding: .hour, value: 1, to: now)!,
                          durationMinutes: 30, location: "Zoom",              isAllDay: false),
            CalendarEvent(title: "Product Review",
                          date: cal.date(byAdding: .hour, value: 3, to: now)!,
                          durationMinutes: 60, location: "Conference Room B", isAllDay: false),
            CalendarEvent(title: "Design Sprint Kickoff",
                          date: cal.date(byAdding: .hour, value: 5, to: now)!,
                          durationMinutes: 90, location: nil,                 isAllDay: false),
        ]
    }

    static func mockTrainInfo(lineName:    String = "Alamein",
                              homeStation: String = "Willison",
                              cityStation: String = "Flinders Street") -> TrainInfo {
        let base = TrainService.secondsSinceMidnight()
        let line = lineName.isEmpty ? "Alamein" : lineName
        let home = homeStation.isEmpty ? "Willison" : homeStation
        let city = cityStation.isEmpty ? "Flinders Street" : cityStation
        return TrainInfo(
            lineName:             line,
            serviceIsGood:        false,
            serviceStatusMessage: "Delays up to 10 min due to earlier signal failure.",
            alerts: [
                TrainServiceAlert(
                    id:                      "mock-1",
                    alertType:               "minor",
                    plainText:               "Delays up to 10 minutes due to earlier signal failure. Check information displays and listen for announcements.",
                    additionalTravelMinutes: 10,
                    disruptionDueTo:         "signal failure"
                )
            ],
            plannedWorks: [
                TrainPlannedWork(id: 1,
                                 title: "Buses replace trains between Camberwell and \(line)",
                                 link:  "https://www.metrotrains.com.au",
                                 type:  "bus-replacement",
                                 upcomingCurrent: "Upcoming",
                                 affectedStations: ["Camberwell", "Riversdale", line]),
                TrainPlannedWork(id: 2,
                                 title: "Weekend maintenance works",
                                 link:  "https://www.metrotrains.com.au",
                                 type:  "night-works",
                                 upcomingCurrent: "Current",
                                 affectedStations: []),
            ],
            homeStationName:       home,
            cityStationName:       city,
            homeStationDepartures: mockDepartures(station: home, toCity: true,  baseSeconds: base + 300),
            cityStationDepartures: mockDepartures(station: city, toCity: false, baseSeconds: base + 600),
            melbourneTimeAtFetch:  TrainService.currentTimeString()
        )
    }

    static func mockDrivingTimes(for destinations: [DrivingDestination]) -> [DrivingTimeEstimate] {
        guard !destinations.isEmpty else { return [] }

        return destinations.enumerated().map { index, destination in
            let minutes = 18 + (index * 7)
            let delay = index == 0 ? 6 : nil
            return DrivingTimeEstimate(
                destination: destination,
                travelMinutes: minutes,
                delayMinutes: delay,
                advisory: delay == nil ? nil : "Traffic is adding time on this route.",
                hasDelay: delay != nil,
                errorMessage: nil
            )
        }
    }

    // Generates `count` evenly-spaced mock departures starting at `baseSeconds`.
    private static func mockDepartures(station: String,
                                       toCity: Bool,
                                       baseSeconds: Int,
                                       count: Int = 5) -> [TrainDeparture] {
        (0..<count).map { i in
            let secs = baseSeconds + i * 600   // 10-minute intervals
            let t    = TrainService.secondsToTimeString(secs)
            return TrainDeparture(
                station:                  station,
                isToCity:                 toCity,
                scheduledTimeStr:         t,
                estimatedArrivalStr:      t,
                estimatedDepartureStr:    t,
                estimatedDepartureSeconds: secs,
                platform:                "1",
                estimatedPlatform:       "1"
            )
        }
    }
}
