//
//  VictorianBusService.swift
//  myLatest
//
//  Combines the local Victorian GTFS schedule database with Transport
//  Victoria GTFS-RT metro bus trip updates to build a live bus stop board.
//

import Foundation
import CoreLocation

final class VictorianBusService: BusDataProviding {
    static let shared = VictorianBusService()
    static let realtimeAPIKeyDefaultsKey = "victorianGTFSRealtimeApiKey"

    private init() {}

    let provider: BusProvider = .victorianPTV

    private let tripUpdatesURL = URL(string: "https://api.opendata.transport.vic.gov.au/opendata/public-transport/gtfs/realtime/v1/bus/trip-updates")!
    private let melbourneTimeZone = TimeZone(identifier: "Australia/Melbourne")!

    func fetchBusInfo(latitude: Double, longitude: Double) async throws -> BusInfo {
        try await VictorianBusGTFSDatabase.shared.ensureReady()

        let nearbyRaw = try await VictorianBusGTFSDatabase.shared.nearbyBusStops(
            latitude: latitude,
            longitude: longitude,
            radiusMeters: 300
        )
        let nearbyStopIds = nearbyRaw.map { $0.stop.stopId }

        let favourites = await MainActor.run { FavouriteBusStopStore.shared.favourites(for: provider) }
        let favouriteStopIds = favourites.map(\.stopId)
        let allStopIds = Array(Set(nearbyStopIds + favouriteStopIds))

        let nowSeconds = VictorianBusGTFSDatabase.melbourneMidnightSeconds()
        let scheduledDepartures: [VictorianBusGTFSDatabase.ScheduledDeparture]
        if allStopIds.isEmpty {
            scheduledDepartures = []
        } else {
            scheduledDepartures = try await VictorianBusGTFSDatabase.shared.departures(
                forStopIds: allStopIds,
                afterSeconds: nowSeconds,
                limitPerStop: 15
            )
        }

        let tripUpdates = await fetchTripUpdates()
        let stopDepartureMap = buildDepartureBoard(
            scheduled: scheduledDepartures,
            tripUpdates: tripUpdates,
            nowSeconds: nowSeconds
        )

        let nearbyStops: [NearbyBusStop] = nearbyRaw.compactMap { stop, distance in
            let departures = stopDepartureMap[stop.stopId] ?? []
            guard !departures.isEmpty else { return nil }
            return NearbyBusStop(
                id: stop.stopId,
                stopName: stop.stopName,
                stopCode: stop.stopCode,
                distanceMeters: Int(distance),
                departures: departures
            )
        }

        let nearbyStopIdSet = Set(nearbyStopIds)
        let userLocation = CLLocation(latitude: latitude, longitude: longitude)
        let favouriteStops: [NearbyBusStop] = favourites.compactMap { favourite in
            guard !nearbyStopIdSet.contains(favourite.stopId) else { return nil }
            let departures = stopDepartureMap[favourite.stopId] ?? []
            guard !departures.isEmpty else { return nil }

            let stopLocation = CLLocation(latitude: favourite.latitude, longitude: favourite.longitude)
            let distance = Int(userLocation.distance(from: stopLocation))

            return NearbyBusStop(
                id: favourite.stopId,
                stopName: favourite.stopName,
                stopCode: favourite.stopCode,
                distanceMeters: distance,
                departures: departures
            )
        }

        return BusInfo(
            provider: provider,
            nearbyStops: nearbyStops,
            favouriteStops: favouriteStops,
            alerts: [],
            localTimeAtFetch: currentMelbourneTimeString(),
            locationAvailable: true
        )
    }

    private func fetchTripUpdates() async -> [String: GTFSRTTripUpdate] {
        let apiKey = UserDefaults.standard.string(forKey: Self.realtimeAPIKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !apiKey.isEmpty else {
            print("⚠️ Victorian GTFS-RT TripUpdates skipped: no realtime key configured in UserDefaults.")
            return [:]
        }

        print("ℹ️ Victorian GTFS-RT TripUpdates using key fingerprint \(redactedKeyFingerprint(for: apiKey)) (length: \(apiKey.count))")

        var components = URLComponents(url: tripUpdatesURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "subscription-key", value: apiKey))
        components?.queryItems = queryItems

        guard let requestURL = components?.url else {
            print("⚠️ Victorian GTFS-RT TripUpdates request could not be constructed")
            return [:]
        }

        var request = URLRequest(url: requestURL)
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue(apiKey, forHTTPHeaderField: "KeyID")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                let responseBody = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if httpResponse.statusCode == 401 {
                    print("⚠️ Victorian GTFS-RT TripUpdates request failed with HTTP 401. Check that the configured key is a valid Transport Victoria Open Data subscription key for the GTFS-RT bus feed.")
                } else {
                    print("⚠️ Victorian GTFS-RT TripUpdates request failed with HTTP \(httpResponse.statusCode)")
                }
                if let responseBody, !responseBody.isEmpty {
                    print("⚠️ Victorian GTFS-RT response body: \(responseBody)")
                }
                return [:]
            }

            let feed = try GTFSRTFeedMessage(data: data)
            var byTripId: [String: GTFSRTTripUpdate] = [:]
            for entity in feed.entities {
                if let tripUpdate = entity.tripUpdate, !tripUpdate.tripId.isEmpty {
                    byTripId[tripUpdate.tripId] = tripUpdate
                }
            }
            return byTripId
        } catch {
            print("⚠️ Victorian GTFS-RT TripUpdates fetch failed: \(error.localizedDescription)")
            return [:]
        }
    }

    private func buildDepartureBoard(
        scheduled: [VictorianBusGTFSDatabase.ScheduledDeparture],
        tripUpdates: [String: GTFSRTTripUpdate],
        nowSeconds: Int
    ) -> [String: [BusDeparture]] {
        var result: [String: [BusDeparture]] = [:]

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = melbourneTimeZone

        for departure in scheduled {
            let tripUpdate = tripUpdates[departure.tripId]
            let stopTimeUpdate = tripUpdate?.stopTimeUpdates.first { update in
                (!update.stopId.isEmpty && update.stopId == departure.stopId)
                    || (update.stopSequence > 0 && Int(update.stopSequence) == departure.stopSequence)
            }

            let delaySeconds: Int
            let predictedTime: String?
            let status: BusDepartureStatus

            if let stopTimeUpdate {
                switch stopTimeUpdate.scheduleRelationship {
                case .skipped:
                    continue
                case .noData:
                    if let tripDelay = tripUpdate?.delay {
                        delaySeconds = Int(tripDelay)
                        predictedTime = secondsToTimeString(departure.departureSeconds + Int(tripDelay))
                        status = statusForDelay(delaySeconds)
                    } else {
                        delaySeconds = 0
                        predictedTime = nil
                        status = .noData
                    }
                default:
                    if let departureEvent = stopTimeUpdate.departure {
                        delaySeconds = Int(departureEvent.delay)
                        if departureEvent.time > 0 {
                            let predictedDate = Date(timeIntervalSince1970: TimeInterval(departureEvent.time))
                            predictedTime = formatter.string(from: predictedDate)
                        } else {
                            predictedTime = secondsToTimeString(departure.departureSeconds + Int(departureEvent.delay))
                        }
                        status = statusForDelay(delaySeconds)
                    } else if let arrivalEvent = stopTimeUpdate.arrival {
                        delaySeconds = Int(arrivalEvent.delay)
                        predictedTime = secondsToTimeString(departure.departureSeconds + Int(arrivalEvent.delay))
                        status = statusForDelay(delaySeconds)
                    } else if let tripDelay = tripUpdate?.delay {
                        delaySeconds = Int(tripDelay)
                        predictedTime = secondsToTimeString(departure.departureSeconds + Int(tripDelay))
                        status = statusForDelay(delaySeconds)
                    } else {
                        delaySeconds = 0
                        predictedTime = nil
                        status = .noData
                    }
                }
            } else if let tripDelay = tripUpdate?.delay {
                delaySeconds = Int(tripDelay)
                predictedTime = secondsToTimeString(departure.departureSeconds + Int(tripDelay))
                status = statusForDelay(delaySeconds)
            } else {
                delaySeconds = 0
                predictedTime = nil
                status = .noData
            }

            let effectiveDepartureSeconds = departure.departureSeconds + delaySeconds
            let minutesAway = max(0, (effectiveDepartureSeconds - nowSeconds) / 60)

            let busDeparture = BusDeparture(
                tripId: departure.tripId,
                routeShortName: departure.routeShortName,
                routeLongName: departure.routeLongName,
                headsign: departure.tripHeadsign,
                scheduledTime: secondsToTimeString(departure.departureSeconds),
                scheduledSeconds: departure.departureSeconds,
                predictedTime: predictedTime,
                delaySeconds: delaySeconds,
                minutesAway: minutesAway,
                status: status,
                stopSequence: departure.stopSequence
            )

            result[departure.stopId, default: []].append(busDeparture)
        }

        return result
    }

    private func statusForDelay(_ delaySeconds: Int) -> BusDepartureStatus {
        if abs(delaySeconds) < 60 {
            return .onTime
        }
        return delaySeconds > 0 ? .late : .early
    }

    private func currentMelbourneTimeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = melbourneTimeZone
        return formatter.string(from: Date())
    }

    private func secondsToTimeString(_ totalSeconds: Int) -> String {
        let safeSeconds = max(0, totalSeconds)
        let hours = (safeSeconds / 3600) % 24
        let minutes = (safeSeconds % 3600) / 60
        let ampm = hours >= 12 ? "PM" : "AM"
        let displayHour = hours == 0 ? 12 : (hours > 12 ? hours - 12 : hours)
        return String(format: "%d:%02d %@", displayHour, minutes, ampm)
    }

    private func redactedKeyFingerprint(for key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else {
            return "\(trimmed.prefix(2))…\(trimmed.suffix(2))"
        }
        return "\(trimmed.prefix(4))…\(trimmed.suffix(4))"
    }
}
