//
//  CalendarService.swift
//  myLatest
//
//  Fetches the next 5 days of calendar events from EventKit.
//  Uses the iOS 17+ requestFullAccessToEvents() API.
//  Falls back to mock data (via MockDataService) on any error.
//

import EventKit
import Foundation

// MARK: - Errors

enum CalendarError: LocalizedError {
    case denied
    case restricted

    var errorDescription: String? {
        switch self {
        case .denied:     return "Calendar access was denied. Please allow access in Settings."
        case .restricted: return "Calendar access is restricted on this device."
        }
    }
}

// MARK: - Calendar Service

final class CalendarService {
    static let shared = CalendarService()

    private let store = EKEventStore()

    private init() {}

    // MARK: - Public API

    /// Returns the `EKEvent` for a previously-fetched `eventIdentifier`, or `nil` if
    /// the event no longer exists or the store hasn't been granted access yet.
    func ekEvent(withIdentifier identifier: String) -> EKEvent? {
        store.event(withIdentifier: identifier)
    }

    /// Requests permission (if needed) then returns all events in the next 5 days,
    /// sorted by start date.
    func fetchUpcomingEvents() async throws -> [CalendarEvent] {

        // 1. Request permission (iOS 17+ API)
        let granted = try await store.requestFullAccessToEvents()
        guard granted else {
            throw CalendarError.denied
        }

        // 2. Build date range: now → now + 5 days
        let now    = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now

        // 3. Fetch from all calendars
        let predicate = store.predicateForEvents(withStart: now, end: endDate, calendars: nil)
        let ekEvents  = store.events(matching: predicate)

        // 4. Sort and map to our model
        return ekEvents
            .sorted { $0.startDate < $1.startDate }
            .map { ek in
                let mins = Int(ek.endDate.timeIntervalSince(ek.startDate) / 60)
                return CalendarEvent(
                    title:           ek.title ?? "Untitled",
                    date:            ek.startDate,
                    durationMinutes: mins,
                    location:        ek.location,
                    isAllDay:        ek.isAllDay,
                    eventIdentifier: ek.eventIdentifier
                )
            }
    }
}
