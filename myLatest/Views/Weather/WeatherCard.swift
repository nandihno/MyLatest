//
//  WeatherCard.swift
//  myLatest
//

import SwiftUI
import Charts

// MARK: - Weather Card

struct WeatherCard: View {
    let weather: WeatherInfo
    var title: String = "Weather"
    @State private var showCharts = false

    private enum TemperatureSeries: CaseIterable {
        case feelsLike
        case airTemp

        var label: String {
            switch self {
            case .feelsLike: return "Feels like"
            case .airTemp: return "Air temp"
            }
        }

        var color: Color {
            switch self {
            case .feelsLike: return .blue
            case .airTemp: return .orange
            }
        }

        var strokeStyle: StrokeStyle {
            switch self {
            case .feelsLike:
                return StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            case .airTemp:
                return StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            }
        }

        func value(for observation: WeatherObservation) -> Double {
            switch self {
            case .feelsLike: return observation.apparentTemp
            case .airTemp: return observation.airTemp
            }
        }
    }

    private struct ChartPoint: Identifiable {
        let id: UUID
        let index: Int
        let observation: WeatherObservation
    }

    private var latest: WeatherObservation? { weather.observations.first }
    /// Reversed so the chart displays oldest → newest left to right.
    private var chartObs: [WeatherObservation] { Array(weather.observations.reversed()) }
    private var chartPoints: [ChartPoint] {
        chartObs.enumerated().map { offset, observation in
            ChartPoint(id: observation.id, index: offset, observation: observation)
        }
    }
    private var xAxisIndices: [Int] {
        guard !chartPoints.isEmpty else { return [] }

        var indices = Array(stride(from: 0, to: chartPoints.count, by: 2))
        let lastIndex = chartPoints.count - 1
        if indices.last != lastIndex {
            indices.append(lastIndex)
        }
        return indices
    }
    private var temperatureDomain: ClosedRange<Double> {
        let temperatures = chartObs.flatMap { [$0.apparentTemp, $0.airTemp] }
        return paddedDomain(for: temperatures, minimumPadding: 1.2)
    }
    private var pressureDomain: ClosedRange<Double> {
        paddedDomain(for: chartObs.map(\.pressureMSL), minimumPadding: 0.6)
    }
    private var humidityDomain: ClosedRange<Double> {
        paddedDomain(for: chartObs.map { Double($0.relHumidity) }, minimumPadding: 4)
    }

    private func paddedDomain(for values: [Double], minimumPadding: Double) -> ClosedRange<Double> {
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 0...1
        }

        let padding = max((maxValue - minValue) * 0.25, minimumPadding)
        return (minValue - padding)...(maxValue + padding)
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {

                Label(title, systemImage: "cloud.sun.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                // ── Current conditions hero ──────────────────────────────
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(weather.stationName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(latest.map { String(format: "%.1f", $0.apparentTemp) } ?? "--")
                                .font(.system(size: 52, weight: .thin))
                            Text("°C")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }

                        Text(latest?.cloud ?? "--")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if let obs = latest {
                            HStack(spacing: 8) {
                                Label(String(format: "%.1f°", obs.airTemp), systemImage: "thermometer.medium")
                                    .foregroundStyle(.orange)
                                Label("\(obs.relHumidity)%", systemImage: "drop.fill")
                                    .foregroundStyle(.blue)
                                Label("\(obs.windDir) \(obs.windSpeedKmh) km/h", systemImage: "wind")
                                    .foregroundStyle(.teal)
                            }
                            .font(.caption2)
                        }
                    }

                    Spacer()

                    Image(systemName: latest?.symbolName ?? "sun.max.fill")
                        .font(.system(size: 52))
                        .symbolRenderingMode(.multicolor)
                }

                if chartObs.count >= 2 {
                    Divider()
                    DisclosureGroup(isExpanded: $showCharts) {
                        observationCharts
                            .padding(.top, 6)
                    } label: {
                        Label("Last 5 hours", systemImage: "chart.xyaxis.line")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Observation chart

    private var observationCharts: some View {
        VStack(alignment: .leading, spacing: 12) {
            chartSection(title: "Temperature") {
                temperatureChart
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Capsule().fill(.blue).frame(width: 16, height: 3)
                    Text("Feels like").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Capsule().fill(.orange).frame(width: 16, height: 3)
                    Text("Air temp").font(.caption2).foregroundStyle(.secondary)
                }
            }

            chartSection(title: "Pressure (hPa)") {
                pressureChart
            }

            chartSection(title: "Humidity (%)") {
                humidityChart
            }

            pressureGuidance
        }
    }

    @ViewBuilder
    private func chartSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            content()
        }
    }

    private var temperatureChart: some View {
        Chart {
            ForEach(TemperatureSeries.allCases, id: \.label) { series in
                ForEach(chartPoints) { point in
                    LineMark(
                        x: .value("Observation", point.index),
                        y: .value(series.label, series.value(for: point.observation)),
                        series: .value("Series", series.label)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(series.color)
                    .lineStyle(series.strokeStyle)
                }
            }
        }
        .chartYScale(domain: temperatureDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.0f°", v)).font(.caption2)
                    }
                }
            }
        }
        .frame(height: 132)
    }

    private var pressureChart: some View {
        Chart {
            ForEach(chartPoints) { point in
                LineMark(
                    x: .value("Observation", point.index),
                    y: .value("Pressure", point.observation.pressureMSL)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        }
        .chartYScale(domain: pressureDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.0f", v)).font(.caption2)
                    }
                }
            }
        }
        .frame(height: 88)
    }

    private var humidityChart: some View {
        Chart {
            ForEach(chartPoints) { point in
                LineMark(
                    x: .value("Observation", point.index),
                    y: .value("Humidity", Double(point.observation.relHumidity))
                )
                .interpolationMethod(.linear)
                .foregroundStyle(.cyan)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        }
        .chartYScale(domain: humidityDomain)
        .chartXAxis {
            AxisMarks(values: xAxisIndices) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let index = value.as(Int.self),
                       chartPoints.indices.contains(index) {
                        Text(chartPoints[index].observation.localDateTime)
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.0f%%", v)).font(.caption2)
                    }
                }
            }
        }
        .frame(height: 92)
    }

    private var pressureGuidance: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Pressure Guide", systemImage: "info.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Standard Pressure: 1013.25 hPa is considered standard atmospheric pressure at sea level.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("High Pressure (Anticyclone): Values above 1013 hPa generally indicate stable, dry, and sunny weather.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Low Pressure (Depression): Values below 1013 hPa indicate unstable, cloudy, and stormy weather.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
