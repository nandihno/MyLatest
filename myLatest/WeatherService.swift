//
//  WeatherService.swift
//  myLatest
//

import Foundation
import CoreLocation

// MARK: - Errors

enum WeatherError: LocalizedError {
    case locationDenied
    case locationUnavailable
    case noStations
    case noForecastLocation
    case network(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .locationDenied:    return "Location access was denied."
        case .locationUnavailable:return "Current device location is unavailable."
        case .noStations:        return "No weather stations available."
        case .noForecastLocation:return "No BOM forecast location found for current coordinates."
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

@MainActor
final class LocationManager: NSObject {
    private let clManager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Requests a one-shot location fix.  Asks for permission first if needed.
    func currentLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw WeatherError.locationUnavailable
        }

        return try await withCheckedThrowingContinuation { [weak self] (cont: CheckedContinuation<CLLocation, Error>) in
            guard let self else {
                cont.resume(throwing: WeatherError.locationUnavailable)
                return
            }

            if let existing = self.continuation {
                existing.resume(throwing: WeatherError.locationUnavailable)
                self.continuation = nil
            }

            self.continuation = cont
            switch clManager.authorizationStatus {
            case .notDetermined:
                clManager.requestWhenInUseAuthorization()
                // locationManagerDidChangeAuthorization will call requestLocation()
            case .authorizedWhenInUse, .authorizedAlways:
                if let cached = self.bestAvailableLocation() {
                    self.deliver(.success(cached))
                } else {
                    clManager.requestLocation()
                }
            case .denied, .restricted:
                self.continuation = nil
                cont.resume(throwing: WeatherError.locationDenied)
            @unknown default:
                clManager.requestWhenInUseAuthorization()
            }
        }
    }

    private func bestAvailableLocation() -> CLLocation? {
        guard let location = clManager.location else { return nil }

        let age = abs(location.timestamp.timeIntervalSinceNow)
        let isRecentEnough = age < 300
        let hasUsableAccuracy = location.horizontalAccuracy >= 0

        return (isRecentEnough && hasUsableAccuracy) ? location : nil
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
        let validLocations = locations.filter { $0.horizontalAccuracy >= 0 }
        if let loc = validLocations.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) {
            deliver(.success(loc))
        } else {
            deliver(.failure(WeatherError.locationUnavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        deliver(.failure(error))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if let cached = bestAvailableLocation() {
                deliver(.success(cached))
            } else {
                manager.requestLocation()
            }
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
    private static let weatherBaseURL = "https://api.weather.bom.gov.au/v1"

    private let locationManager = LocationManager()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

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

    struct WeatherBundle {
        let weather: WeatherInfo
        let forecast: DailyForecastInfo?
    }

    /// Full weather tab pipeline using a single location fix.
    func fetchWeatherBundle() async throws -> WeatherBundle {
        let deviceLocation = try await locationManager.currentLocation()
        async let weatherTask = fetchWeather(for: deviceLocation)
        async let forecastTask = fetchDailyForecast(for: deviceLocation)
        let weather = try await weatherTask
        let forecast = try? await forecastTask
        return WeatherBundle(weather: weather, forecast: forecast)
    }

    /// Full pipeline: device location → nearest station → BOM fetch → WeatherInfo
    func fetchWeather() async throws -> WeatherInfo {
        let deviceLocation = try await locationManager.currentLocation()
        return try await fetchWeather(for: deviceLocation)
    }

    /// Forecast pipeline: location search (lat/lon) -> geohash -> daily forecast.
    func fetchDailyForecast() async throws -> DailyForecastInfo {
        let deviceLocation = try await locationManager.currentLocation()
        return try await fetchDailyForecast(for: deviceLocation)
    }

    // MARK: - Shared pipeline steps

    private func fetchWeather(for deviceLocation: CLLocation) async throws -> WeatherInfo {

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
            try rethrowIfCancelled(error)
            throw WeatherError.network(error)
        }

        // 4. Decode
        let response: BOMResponse
        do {
            response = try JSONDecoder().decode(BOMResponse.self, from: rawData)
        } catch {
            throw WeatherError.decoding(error)
        }

        // 5. Map → WeatherInfo (first 10 observations = 5 hours at BOM's 30-min cadence)
        return mapToWeatherInfo(response: response, fallbackTitle: station.title)
    }

    private func fetchDailyForecast(for deviceLocation: CLLocation) async throws -> DailyForecastInfo {
        let locationLookup = try await fetchLocationLookup(lat: deviceLocation.coordinate.latitude,
                                                           lon: deviceLocation.coordinate.longitude)
        guard let bomLocation = locationLookup.data.first else {
            throw WeatherError.noForecastLocation
        }

        guard let forecastURL = URL(string: "\(Self.weatherBaseURL)/locations/\(bomLocation.geohash)/forecasts/daily") else {
            throw WeatherError.noForecastLocation
        }

        let rawData: Data
        do {
            let (data, _) = try await session.data(from: forecastURL)
            rawData = data
        } catch {
            try rethrowIfCancelled(error)
            throw WeatherError.network(error)
        }

        let response: BOMDailyForecastResponse
        do {
            response = try JSONDecoder().decode(BOMDailyForecastResponse.self, from: rawData)
        } catch {
            throw WeatherError.decoding(error)
        }

        let days = response.data.prefix(7).map { point in
            DailyForecastDay(
                id: Self.isoDay(from: point.date),
                date: Self.isoDay(from: point.date),
                chanceOfNoRainCategory: point.rain?.chanceOfNoRainCategory,
                rainChancePercent: point.rain?.chance,
                rainAmountMinMm: point.rain?.amount?.min,
                rainAmountMaxMm: point.rain?.amount?.max,
                tempMax: point.tempMax,
                tempMin: point.tempMin,
                extendedText: point.extendedText,
                shortText: point.shortText,
                fireDanger: point.fireDanger,
                uvCategory: point.uv?.category,
                now: point.now.map {
                    DailyForecastNow(
                        isNight: $0.isNight,
                        nowLabel: $0.nowLabel,
                        laterLabel: $0.laterLabel,
                        tempNow: $0.tempNow,
                        tempLater: $0.tempLater
                    )
                }
            )
        }

        return DailyForecastInfo(locationName: bomLocation.name,
                                 geohash: bomLocation.geohash,
                                 days: Array(days))
    }

    // MARK: - Mapping

    private func mapToWeatherInfo(response: BOMResponse, fallbackTitle: String) -> WeatherInfo {
        let stationName = response.observations.header.first?.name ?? fallbackTitle

        let observations: [WeatherObservation] = response.observations.data
            .prefix(10)
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

    private func fetchLocationLookup(lat: Double, lon: Double) async throws -> BOMLocationSearchResponse {
        var components = URLComponents(string: "\(Self.weatherBaseURL)/locations")
        components?.queryItems = [URLQueryItem(name: "search", value: "\(lat),\(lon)")]

        guard let url = components?.url else {
            throw WeatherError.noForecastLocation
        }

        let rawData: Data
        do {
            let (data, _) = try await session.data(from: url)
            rawData = data
        } catch {
            try rethrowIfCancelled(error)
            throw WeatherError.network(error)
        }

        do {
            return try JSONDecoder().decode(BOMLocationSearchResponse.self, from: rawData)
        } catch {
            throw WeatherError.decoding(error)
        }
    }

    /// Parses a full ISO 8601 UTC datetime (e.g. "2026-03-13T13:00:00Z") and
    /// returns a "yyyy-MM-dd" string in the **device's local timezone**, so that
    /// forecast dates reflect the user's calendar day rather than the UTC day.
    private static func isoDay(from value: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            // DateFormatter defaults to the system timezone — correct behaviour.
            return fmt.string(from: date)
        }
        // Fallback: strip time component (UTC-based, acceptable if parsing fails).
        return String(value.prefix(10))
    }
}
