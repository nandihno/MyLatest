//
//  BusCard.swift
//  myLatest
//

import SwiftUI

// MARK: - Bus Card

struct BusCard: View {
    let busInfo: BusInfo
    @Environment(\.themePalette) private var palette

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Label("Bus Departures", systemImage: "bus.fill")
                        .font(.transit(18, weight: .bold))
                        .foregroundStyle(palette.accent)
                    Spacer()
                    Text(busInfo.localTimeAtFetch)
                        .font(.transit(11, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(palette.surfaceRaised, in: Capsule())
                }

                if !busInfo.locationAvailable {
                    Label("Location unavailable. Enable Location Services to see nearby bus stops.",
                          systemImage: "location.slash.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.warning)
                } else if busInfo.nearbyStops.isEmpty && busInfo.favouriteStops.isEmpty {
                    Label("No bus stops found within 300m. Add favourite stops in Settings.",
                          systemImage: "mappin.slash")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                } else {
                    // Alerts
                    ForEach(busInfo.alerts) { alert in
                        BusAlertRow(alert: alert)
                    }

                    // Nearby stops with departures
                    if !busInfo.nearbyStops.isEmpty {
                        Label("Nearby", systemImage: "location.fill")
                            .font(.caption.bold())
                            .foregroundStyle(palette.textSecondary)
                            .padding(.top, 4)
                        ForEach(busInfo.nearbyStops) { stop in
                            BusStopSection(stop: stop)
                        }
                    }

                    // Favourite stops
                    if !busInfo.favouriteStops.isEmpty {
                        if !busInfo.nearbyStops.isEmpty {
                            Divider()
                                .padding(.vertical, 4)
                        }
                        Label("Favourites", systemImage: "star.fill")
                            .font(.caption.bold())
                            .foregroundStyle(palette.accent)
                        ForEach(busInfo.favouriteStops) { stop in
                            BusStopSection(stop: stop)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Bus Alert Row

struct BusAlertRow: View {
    let alert: BusAlert

    @Environment(\.themePalette) private var palette
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: alert.severity.symbolName)
                    .foregroundStyle(alertColor)
                    .font(.subheadline)

                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.effect)
                        .font(.caption.bold())
                        .foregroundStyle(alertColor)
                    Text(alert.headerText)
                        .font(.caption)
                        .lineLimit(isExpanded ? nil : 2)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.toggle() } }

            if isExpanded, let desc = alert.descriptionText {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.leading, 28)
            }
        }
        .padding(8)
        .background(alertColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var alertColor: Color {
        switch alert.severity {
        case .severe:  return AppTheme.danger
        case .warning: return AppTheme.warning
        case .info:    return AppTheme.info
        }
    }
}

// MARK: - Bus Stop Section

struct BusStopSection: View {
    let stop: NearbyBusStop

    @Environment(\.themePalette) private var palette
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Stop header — tappable to collapse/expand
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.stopName)
                            .font(.transit(17, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                        if let code = stop.stopCode {
                            Text("Stop #\(code)")
                                .font(.caption2)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                    Spacer()
                    Text("\(stop.distanceMeters)m away")
                        .font(.transit(12, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.surfaceRaised)
                        .clipShape(Capsule())
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(palette.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                // Departure rows
                ForEach(stop.departures) { departure in
                    BusDepartureRow(departure: departure)
                }
            }
        }
    }
}

// MARK: - Bus Departure Row

struct BusDepartureRow: View {
    let departure: BusDeparture
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            // Route badge
            Text(departure.routeShortName)
                .font(.transit(14, weight: .heavy).monospacedDigit())
                .foregroundStyle(Color.black.opacity(0.84))
                .frame(minWidth: 42)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(palette.buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Headsign / route name
            VStack(alignment: .leading, spacing: 1) {
                Text(departure.headsign ?? departure.routeLongName)
                    .font(.transit(14, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                timeDetailLine
            }

            Spacer()

            // Minutes away + status
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(departure.minutesAway)")
                        .font(.transit(24, weight: .heavy).monospacedDigit())
                        .foregroundStyle(palette.textPrimary)
                    Text("min")
                        .font(.transit(12, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                }
                Text(departure.status.rawValue)
                    .font(.transit(12, weight: .bold))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var timeDetailLine: some View {
        HStack(spacing: 4) {
            Text("Sched \(departure.scheduledTime)")
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)

            if let predicted = departure.predictedTime {
                Text("Pred \(predicted)")
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }

            if departure.delaySeconds != 0 && departure.status != .noData {
                let delayStr = departure.delaySeconds > 0
                    ? "+\(departure.delaySeconds)s"
                    : "\(departure.delaySeconds)s"
                Text("Delay: \(delayStr)")
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var statusColor: Color {
        switch departure.status {
        case .onTime:  return AppTheme.success
        case .early:   return AppTheme.info
        case .late:    return AppTheme.warning
        case .noData:  return palette.textSecondary
        case .skipped: return AppTheme.danger
        }
    }
}
