//
//  CalendarCard.swift
//  myLatest
//

import SwiftUI

// MARK: - Calendar Card

struct CalendarCard: View {
    let events: [CalendarEvent]

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                Label("Next 2 Days", systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if events.isEmpty {
                    Text("No upcoming events")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        EventRow(event: event)
                        if event.id != events.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: CalendarEvent
    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette
    @State private var showDetail = false

    private var timeText: String {
        event.isAllDay
            ? "All day"
            : event.date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        Button(action: openEvent) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.accent)
                    .frame(width: 4, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.transit(16, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(timeText)
                        .font(.transit(12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                    if let location = event.location {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.caption2)
                            .foregroundStyle(palette.textTertiary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            if let identifier = event.eventIdentifier {
                EventDetailSheet(eventIdentifier: identifier)
            }
        }
    }

    private func openEvent() {
        if event.eventIdentifier != nil {
            showDetail = true
        } else {
            let interval = Int(event.date.timeIntervalSinceReferenceDate)
            if let url = URL(string: "calshow://\(interval)") { openURL(url) }
        }
    }
}
