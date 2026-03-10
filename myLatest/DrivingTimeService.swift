//
//  DrivingTimeService.swift
//  myLatest
//

import CoreLocation
import Foundation
import MapKit

@MainActor
final class DrivingTimeService {
    static let shared = DrivingTimeService()

    private let locationManager = LocationManager()

    private init() {}

    func fetchDrivingTimes() async throws -> [DrivingTimeEstimate] {
        let destinations = DrivingDestinationStore.shared.all
        guard !destinations.isEmpty else { return [] }

        let sourceLocation = try await locationManager.currentLocation()

        return await withTaskGroup(of: (Int, DrivingTimeEstimate).self) { group in
            for (index, destination) in destinations.enumerated() {
                group.addTask {
                    let estimate = await Self.fetchEstimate(from: sourceLocation, to: destination)
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

    private static func fetchEstimate(from sourceLocation: CLLocation,
                                      to destination: DrivingDestination) async -> DrivingTimeEstimate {
        do {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: sourceLocation.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
            request.transportType = .automobile
            request.departureDate = Date()

            let response = try await calculateDirections(for: request)
            guard let route = response.routes.first else {
                return .unavailable(destination: destination, message: "No driving route found.")
            }

            let notices = route.advisoryNotices
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let delayMinutes = parseDelayMinutes(from: notices)
            let hasDelay = (delayMinutes ?? 0) > 0 || noticesSuggestDelay(notices)

            return DrivingTimeEstimate(
                destination: destination,
                travelMinutes: roundedMinutes(from: route.expectedTravelTime),
                delayMinutes: delayMinutes,
                advisory: notices.first,
                hasDelay: hasDelay,
                errorMessage: nil
            )
        } catch is CancellationError {
            return .unavailable(destination: destination, message: "Route lookup cancelled.")
        } catch {
            return .unavailable(destination: destination, message: error.localizedDescription)
        }
    }

    private static func calculateDirections(for request: MKDirections.Request) async throws -> MKDirections.Response {
        let directions = MKDirections(request: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                directions.calculate { response, error in
                    if let response {
                        continuation.resume(returning: response)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: LocationError.unavailable)
                    }
                }
            }
        } onCancel: {
            directions.cancel()
        }
    }

    private static func roundedMinutes(from travelTime: TimeInterval) -> Int {
        max(1, Int((travelTime / 60).rounded()))
    }

    private static func parseDelayMinutes(from notices: [String]) -> Int? {
        let patterns = [
            #"\b(\d+)\s*(?:min|mins|minute|minutes)\b"#,
            #"\bdelay(?:ed|s)?\s*(?:up to\s*)?(\d+)\s*(?:min|mins|minute|minutes)\b"#
        ]

        for notice in notices {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    continue
                }

                let range = NSRange(notice.startIndex..<notice.endIndex, in: notice)
                guard
                    let match = regex.firstMatch(in: notice, options: [], range: range),
                    match.numberOfRanges > 1,
                    let minuteRange = Range(match.range(at: 1), in: notice),
                    let minutes = Int(notice[minuteRange])
                else { continue }

                return minutes
            }
        }

        return nil
    }

    private static func noticesSuggestDelay(_ notices: [String]) -> Bool {
        let delayKeywords = [
            "delay",
            "traffic",
            "congestion",
            "roadworks",
            "road work",
            "incident",
            "accident",
            "closure",
            "slow"
        ]

        return notices.contains { notice in
            let lowercased = notice.lowercased()
            return delayKeywords.contains(where: lowercased.contains)
        }
    }
}
