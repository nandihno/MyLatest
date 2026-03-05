//
//  HealthView.swift
//  myLatest
//
//  Health tab: 7-day sleep summary + today's heart-rate chart.
//  Uses mock data for now — HealthKit integration is Step 5.
//

import SwiftUI
import Charts

// MARK: - Root view

struct HealthView: View {
    @State private var healthData: HealthData?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading || healthData == nil {
                    loadingBody
                } else {
                    scrollBody
                }
            }
            .navigationTitle("Health")
            .navigationBarTitleDisplayMode(.large)
        }
        .task { await load() }
    }

    // MARK: Loading skeleton

    private var loadingBody: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView("Loading health data…")
                .progressViewStyle(.circular)
            Spacer()
        }
    }

    // MARK: Loaded content

    private var scrollBody: some View {
        ScrollView {
            VStack(spacing: 16) {
                SleepCard(records: healthData!.sleepRecords)
                HeartRateCard(stats: healthData!.heartRateStats)
            }
            .padding()
        }
        .refreshable { await load() }
    }

    // MARK: Data fetch

    private func load() async {
        isLoading = true
        healthData = await HealthService.shared.fetchHealthData()
        isLoading = false
    }
}

// MARK: - Sleep card

private struct SleepCard: View {
    let records: [SleepRecord]

    /// Recommended nightly sleep (hours)
    private let goalHours: Double = 8.0

    private var avgHours: Double {
        guard !records.isEmpty else { return 0 }
        return records.map(\.totalHoursDecimal).reduce(0, +) / Double(records.count)
    }

    /// Upper bound for the Y-axis: at least goalHours+1, rounded up to next even number.
    private var chartYMax: Double {
        let dataMax = records.map(\.totalHoursDecimal).max() ?? 0
        let raw = max(dataMax, goalHours) + 1.0
        return (raw / 2.0).rounded(.up) * 2.0
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ─────────────────────────────────────────────────
                HStack(alignment: .firstTextBaseline) {
                    Label("Sleep", systemImage: "moon.zzz.fill")
                        .font(.headline)
                        .foregroundStyle(.indigo)
                    Spacer()
                    Text("7-day avg  \(avgHours, specifier: "%.1f")h")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // ── Bar chart ──────────────────────────────────────────────
                Chart {
                    // 8-hour goal rule
                    RuleMark(y: .value("Goal", goalHours))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("8h")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                    ForEach(records) { rec in
                        BarMark(
                            x: .value("Day",   rec.weekdayLabel),
                            y: .value("Sleep", rec.totalHoursDecimal)
                        )
                        .foregroundStyle(barColour(rec.qualityLevel))
                        .cornerRadius(5)
                        .annotation(position: .top, alignment: .center) {
                            Text(rec.durationLabel)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartYScale(domain: 0...chartYMax)
                .chartYAxis {
                    AxisMarks(values: stride(from: 0, through: Int(chartYMax), by: 2).map { $0 }) { val in
                        AxisGridLine()
                        AxisValueLabel {
                            if let h = val.as(Int.self) { Text("\(h)h") }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                    }
                }
                .frame(height: 260)

                // ── Legend ─────────────────────────────────────────────────
                HStack(spacing: 12) {
                    legendDot(.green,  "Good  ≥7.5h")
                    legendDot(.yellow, "Fair  6–7.5h")
                    legendDot(.red,    "Poor  <6h")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                // ── Stage breakdown (last night) ───────────────────────────
                if let last = records.last {
                    Divider()
                    lastNightBreakdown(last)
                }
            }
        }
    }

    // MARK: Helpers

    private func barColour(_ q: SleepRecord.QualityLevel) -> Color {
        switch q {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .red
        }
    }

    @ViewBuilder
    private func legendDot(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(label)
        }
    }

    @ViewBuilder
    private func lastNightBreakdown(_ rec: SleepRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last night · \(rec.durationLabel)")
                .font(.caption.weight(.semibold))

            HStack(spacing: 8) {
                stageBar("Deep",  rec.deepMinutes,  rec.totalMinutes, .indigo)
                stageBar("REM",   rec.remMinutes,   rec.totalMinutes, .purple)
                stageBar("Core",  rec.coreMinutes,  rec.totalMinutes, .blue)
            }
        }
    }

    @ViewBuilder
    private func stageBar(_ label: String, _ mins: Int, _ total: Int, _ colour: Color) -> some View {
        let frac = total > 0 ? Double(mins) / Double(total) : 0
        VStack(spacing: 3) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(colour.opacity(0.25))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(colour)
                            .frame(width: geo.size.width * frac)
                    }
            }
            .frame(height: 8)

            HStack {
                Text(label)
                Spacer()
                Text(SleepRecord(date: .now,
                                 totalMinutes: mins,
                                 deepMinutes: 0,
                                 remMinutes: 0,
                                 coreMinutes: 0).durationLabel)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Heart-rate card

private struct HeartRateCard: View {
    let stats: HeartRateStats

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ─────────────────────────────────────────────────
                HStack(alignment: .firstTextBaseline) {
                    Label("Heart Rate", systemImage: "heart.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Spacer()
                    Text("Today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // ── Current BPM hero ───────────────────────────────────────
                if let latest = stats.latest {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(latest)")
                            .font(.system(size: 48, weight: .semibold, design: .rounded))
                        Text("BPM")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                // ── Min / Avg / Max pills ──────────────────────────────────
                HStack(spacing: 16) {
                    statPill("Min",  "\(stats.min)",  .blue)
                    statPill("Avg",  "\(stats.average)", .orange)
                    statPill("Max",  "\(stats.max)",  .red)
                }

                // ── Line chart ─────────────────────────────────────────────
                if !stats.samples.isEmpty {
                    Chart {
                        ForEach(stats.samples) { sample in
                            LineMark(
                                x: .value("Time", sample.timestamp),
                                y: .value("BPM",  sample.bpm)
                            )
                            .foregroundStyle(.red.gradient)
                            .interpolationMethod(.catmullRom)

                            AreaMark(
                                x: .value("Time", sample.timestamp),
                                yStart: .value("Min", stats.min - 5),
                                yEnd:   .value("BPM", sample.bpm)
                            )
                            .foregroundStyle(.red.opacity(0.08).gradient)
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 3)) { val in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                    .chartYAxis {
                        AxisMarks { val in
                            AxisGridLine()
                            AxisValueLabel {
                                if let v = val.as(Int.self) { Text("\(v)") }
                            }
                        }
                    }
                    .chartYScale(domain: (stats.min - 10)...(stats.max + 10))
                    .frame(height: 200)
                } else {
                    Text("No readings yet today.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
        }
    }

    @ViewBuilder
    private func statPill(_ label: String, _ value: String, _ colour: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(colour)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(colour.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Preview

#Preview {
    HealthView()
}
