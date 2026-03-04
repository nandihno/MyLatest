//
//  WeatherService.swift
//  myLatest
//

import Foundation
import CoreLocation

// MARK: - Errors

enum WeatherError: LocalizedError {
    case locationDenied
    case noStations
    case network(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .locationDenied:    return "Location access was denied."
        case .noStations:        return "No weather stations available."
        case .network(let e):    return "Network error: \(e.localizedDescription)"
        case .decoding(let e):   return "Data error: \(e.localizedDescription)"
        }
    }
}

// MARK: - Location Manager
//
// Wraps CLLocationManager in a clean async/await interface.
// The @preconcurrency attribute silences strict-concurrency warnings for
// CLLocationManagerDelegate callbacks, which are always dispatched on the
// main thread by the system.

final class LocationManager: NSObject {
    private let clManager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Requests a one-shot location fix.  Asks for permission first if needed.
    func currentLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { [weak self] cont in
            guard let self else {
                cont.resume(throwing: WeatherError.noStations)
                return
            }
            self.continuation = cont
            switch clManager.authorizationStatus {
            case .notDetermined:
                clManager.requestWhenInUseAuthorization()
                // locationManagerDidChangeAuthorization will call requestLocation()
            case .authorizedWhenInUse, .authorizedAlways:
                clManager.requestLocation()
            case .denied, .restricted:
                self.continuation = nil
                cont.resume(throwing: WeatherError.locationDenied)
            @unknown default:
                clManager.requestWhenInUseAuthorization()
            }
        }
    }

    private func deliver(_ result: Result<CLLocation, Error>) {
        switch result {
        case .success(let loc): continuation?.resume(returning: loc)
        case .failure(let err): continuation?.resume(throwing: err)
        }
        continuation = nil
    }
}

extension LocationManager: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        deliver(.success(loc))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        deliver(.failure(error))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            deliver(.failure(WeatherError.locationDenied))
        default:
            break
        }
    }
}

// MARK: - Weather Service

final class WeatherService {
    static let shared = WeatherService()

    private let locationManager = LocationManager()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private init() {}

    /// Full pipeline: device location → nearest station → BOM fetch → WeatherInfo
    func fetchWeather() async throws -> WeatherInfo {

        // 1. Device location
        let deviceLocation = try await locationManager.currentLocation()

        // 2. Nearest station — searches built-in + any user-added custom stations
        let allStations = WeatherStationStore.shared.all
        guard let station = WeatherStation.nearest(to: deviceLocation, from: allStations) else {
            throw WeatherError.noStations
        }

        // 3. Fetch BOM JSON
        guard let url = URL(string: station.url) else { throw WeatherError.noStations }
        let rawData: Data
        do {
            let (data, _) = try await session.data(from: url)
            rawData = data
        } catch {
            throw WeatherError.network(error)
        }

        // 4. Decode
        let response: BOMResponse
        do {
            response = try JSONDecoder().decode(BOMResponse.self, from: rawData)
        } catch {
            throw WeatherError.decoding(error)
        }

        // 5. Map → WeatherInfo (first 5 observations)
        return mapToWeatherInfo(response: response, fallbackTitle: station.title)
    }

    // MARK: - Mapping

    private func mapToWeatherInfo(response: BOMResponse, fallbackTitle: String) -> WeatherInfo {
        let stationName = response.observations.header.first?.name ?? fallbackTitle

        let observations: [WeatherObservation] = response.observations.data
            .prefix(5)
            .map { point in
                // Empty string or "-" from BOM means no cloud = clear/sunny
                let raw = (point.cloud ?? "").trimmingCharacters(in: .whitespaces)
                let cloud = (raw.isEmpty || raw == "-") ? "Sunny" : raw

                let windDir = (point.windDir?.trimmingCharacters(in: .whitespaces) ?? "")
                    .replacingOccurrences(of: "-", with: "—")

                return WeatherObservation(
                    localDateTime: Self.timeOnly(from: point.localDateTime),
                    apparentTemp:  point.apparentT ?? point.airTemp ?? 0,
                    airTemp:       point.airTemp ?? 0,
                    relHumidity:   point.relHum ?? 0,
                    cloud:         cloud,
                    windDir:       windDir.isEmpty ? "—" : windDir,
                    windSpeedKmh:  point.windSpdKmh ?? 0
                )
            }

        return WeatherInfo(stationName: stationName, observations: observations)
    }

    /// Strips the day prefix from BOM local_date_time.
    /// "04/11:30am" → "11:30am"
    private static func timeOnly(from raw: String) -> String {
        let parts = raw.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : raw
    }
}
