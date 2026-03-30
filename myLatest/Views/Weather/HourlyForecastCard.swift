//
//  HourlyForecastCard.swift
//  myLatest
//

import SwiftUI

// MARK: - Hourly Forecast Card

struct HourlyForecastCard: View {
    let hourly: HourlyForecastInfo?

    var body: some View {
        if let hourly, !hourly.hours.isEmpty {
            CardContainer {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Next \(hourly.hours.count) Hours", systemImage: "clock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(hourly.hours) { hour in
                                VStack(spacing: 8) {
                                    Text(hour.time)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    Image(systemName: hourlySymbol(for: hour))
                                        .font(.title3)
                                        .foregroundStyle(hourlySymbolColor(for: hour))
                                        .frame(height: 24)

                                    Text("\(hour.temp)°")
                                        .font(.title3.weight(.medium))

                                    Text("Feels \(hour.feelsLike)°")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    // Rain chance pill
                                    HStack(spacing: 2) {
                                        Image(systemName: "drop.fill")
                                            .font(.system(size: 8))
                                        Text("\(hour.rainChance)%")
                                            .font(.caption2.weight(.medium))
                                    }
                                    .foregroundStyle(hour.rainChance > 30 ? .blue : .secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(hour.rainChance > 30
                                                  ? Color.blue.opacity(0.12)
                                                  : Color.secondary.opacity(0.08))
                                    )
                                }
                                .frame(minWidth: 58)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
    }

    private func hourlySymbol(for hour: HourlyForecastHour) -> String {
        let desc = hour.iconDescriptor.lowercased()
        if desc.contains("storm") || desc.contains("thunder") { return "cloud.bolt.rain.fill" }
        if desc.contains("shower") || desc.contains("rain")   { return "cloud.rain.fill" }
        if desc.contains("cloudy") && hour.isNight             { return "cloud.moon.fill" }
        if desc.contains("cloudy")                             { return "cloud.fill" }
        if desc.contains("partly") || desc.contains("mostly_sunny") {
            return hour.isNight ? "cloud.moon.fill" : "cloud.sun.fill"
        }
        if desc.contains("hazy") || desc.contains("fog")      { return "cloud.fog.fill" }
        if hour.isNight                                         { return "moon.stars.fill" }
        return "sun.max.fill"
    }

    private func hourlySymbolColor(for hour: HourlyForecastHour) -> Color {
        let desc = hour.iconDescriptor.lowercased()
        if desc.contains("storm")                              { return .purple }
        if desc.contains("rain") || desc.contains("shower")   { return .blue }
        if desc.contains("cloudy")                             { return .gray }
        if hour.isNight                                         { return .indigo }
        return .orange
    }
}
