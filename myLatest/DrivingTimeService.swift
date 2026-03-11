//
//  DrivingTimeService.swift
//  myLatest
//

import CoreLocation
import Foundation

@MainActor
final class DrivingTimeService {
    static let shared = DrivingTimeService()

    private let locationManager = LocationManager()

    private static let endpoint = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!

    private init() {}

    func fetchDrivingTimes(apiKey: String) async throws -> [DrivingTimeEstimate] {
        let destinations = DrivingDestinationStore.shared.all
        guard !destinations.isEmpty else { return [] }

        guard !apiKey.isEmpty else {
            return destinations.map {
                .unavailable(destination: $0, message: "Google Maps API key not set. Add it in Settings.")
            }
        }

        let sourceLocation = try await locationManager.currentLocation()

        return await withTaskGroup(of: (Int, DrivingTimeEstimate).self) { group in
            for (index, destination) in destinations.enumerated() {
                group.addTask {
                    let estimate = await Self.fetchEstimate(
                        from: sourceLocation,
                        to: destination,
                        apiKey: apiKey
                    )
                    return (index, estimate)
                }
            }

            var indexedResults: [(Int, DrivingTimeEstimate)] = []
            for await item in group {
                indexedResults.append(item)
            }

            return indexedResults
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    // MARK: - Google Routes API

    private static func fetchEstimate(
        from sourceLocation: CLLocation,
        to destination: DrivingDestination,
        apiKey: String
    ) async -> DrivingTimeEstimate {
        do {
            let body = GoogleRoutesRequest(
                origin: .init(latitude: sourceLocation.coordinate.latitude,
                              longitude: sourceLocation.coordinate.longitude),
                destination: .init(latitude: destination.latitude,
                                   longitude: destination.longitude)
            )

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
            request.setValue(
                "routes.duration,routes.staticDuration,routes.distanceMeters,routes.travelAdvisory",
                forHTTPHeaderField: "X-Goog-FieldMask"
            )
            request.httpBody = try JSONEncoder().encode(body)

            let (data, httpResponse) = try await URLSession.shared.data(for: request)

            if let http = httpResponse as? HTTPURLResponse, http.statusCode != 200 {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                return .unavailable(destination: destination, message: "Google API error: \(message)")
            }

            let decoded = try JSONDecoder().decode(GoogleRoutesResponse.self, from: data)
            guard let route = decoded.routes?.first else {
                return .unavailable(destination: destination, message: "No driving route found.")
            }

            let durationSec = parseDurationSeconds(route.duration)
            let staticSec = parseDurationSeconds(route.staticDuration)
            let travelMinutes = max(1, Int((Double(durationSec) / 60.0).rounded()))

            var delayMinutes: Int? = nil
            var hasDelay = false
            if durationSec > 0, staticSec > 0, durationSec > staticSec {
                let delaySec = durationSec - staticSec
                let delayMins = Int((Double(delaySec) / 60.0).rounded())
                if delayMins >= 1 {
                    delayMinutes = delayMins
                    hasDelay = true
                }
            }

            let advisory = route.travelAdvisory.flatMap { adv -> String? in
                guard let warnings = adv.speedReadingIntervals, !warnings.isEmpty else { return nil }
                let slowCount = warnings.filter { $0.speed == "SLOW" || $0.speed == "TRAFFIC_JAM" }.count
                if slowCount == 0 { return nil }
                return "\(slowCount) slow/congested segment\(slowCount == 1 ? "" : "s") on route"
            }

            if advisory != nil { hasDelay = true }

            return DrivingTimeEstimate(
                destination: destination,
                travelMinutes: travelMinutes,
                delayMinutes: delayMinutes,
                advisory: advisory,
                hasDelay: hasDelay,
                errorMessage: nil
            )
        } catch is CancellationError {
            return .unavailable(destination: destination, message: "Route lookup cancelled.")
        } catch {
            return .unavailable(destination: destination, message: error.localizedDescription)
        }
    }

    /// Parses Google's duration string format "123s" → 123
    private static func parseDurationSeconds(_ value: String?) -> Int {
        guard let value, value.hasSuffix("s"),
              let secs = Int(value.dropLast()) else { return 0 }
        return secs
    }
}

// MARK: - Google Routes API Models

private struct GoogleRoutesRequest: Encodable {
    let origin: Waypoint
    let destination: Waypoint
    let travelMode = "DRIVE"
    let routingPreference = "TRAFFIC_AWARE_OPTIMAL"

    struct Waypoint: Encodable {
        let location: LatLngWrapper

        init(latitude: Double, longitude: Double) {
            self.location = LatLngWrapper(latLng: LatLng(latitude: latitude, longitude: longitude))
        }
    }

    struct LatLngWrapper: Encodable {
        let latLng: LatLng
    }

    struct LatLng: Encodable {
        let latitude: Double
        let longitude: Double
    }
}

private struct GoogleRoutesResponse: Decodable {
    let routes: [Route]?

    struct Route: Decodable {
        let duration: String?
        let staticDuration: String?
        let distanceMeters: Int?
        let travelAdvisory: TravelAdvisory?
    }

    struct TravelAdvisory: Decodable {
        let speedReadingIntervals: [SpeedReading]?
    }

    struct SpeedReading: Decodable {
        let speed: String?
    }
}
