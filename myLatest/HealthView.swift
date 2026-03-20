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
    @State private var lastUpdatedAt: Date?

    @AppStorage("claudeApiKey") private var claudeApiKey: String = ""
    @AppStorage("aiProvider") private var aiProviderRaw: String = AIProvider.appleIntelligence.rawValue
    @AppStorage("userAge")      private var userAge:      String = ""
    @AppStorage("userExtraInformation") private var userExtraInformation: String = ""
    @State private var isAnalysing    = false
    @State private var analysisResult: String? = nil
    @State private var showAnalysis   = false

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .appleIntelligence
    }
    private var aiIsAvailable: Bool {
        aiProvider == .appleIntelligence || !claudeApiKey.isEmpty
    }
    private var poweredByLabel: String {
        aiProvider == .claude ? "Powered by Claude" : "Powered by Apple Intelligence"
    }

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
            .sheet(isPresented: $showAnalysis) { analysisSheet }
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
                if let lastUpdatedAt {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Last updated at \(lastUpdatedAt.formatted(date: .omitted, time: .shortened))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DailyBriefCard(brief: healthData!.dailyBrief, userAge: Int(userAge) ?? 0)
                WorkoutDistanceCard(data: healthData!.workoutData.weeklyDistance)
                ActivitySummaryCard(activities:    healthData!.workoutData.activities,
                                    weekStartDate: healthData!.workoutData.weeklyDistance.weekStartDate)
                SleepCard(records: healthData!.sleepRecords)
                HeartRateCard(stats: healthData!.heartRateStats)
                claudeAnalyseCard
            }
            .padding()
        }
        .refreshable { await load() }
    }

    // MARK: Data fetch

    private func load() async {
        // Only show the full-screen spinner on the very first load (no data yet).
        // On pull-to-refresh, keep the existing cards visible — the system spinner
        // at the top provides all the visual feedback needed.
        if healthData == nil {
            isLoading = true
        }
        healthData = await HealthService.shared.fetchHealthData()
        lastUpdatedAt = Date()
        isLoading = false
    }

    // MARK: Claude Analysis

    private var claudeAnalyseCard: some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple.opacity(0.18), Color.pink.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile.fill")
                        .font(.title3)
                        .symbolRenderingMode(.multicolor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AI Health Briefing")
                            .font(.headline)
                        Text(poweredByLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if aiProvider == .claude && claudeApiKey.isEmpty {
                    Label("Add your Claude API key in Settings to enable.", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(action: analyseHealth) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Get My Health Briefing")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        !aiIsAvailable
                        ? LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.25)],
                                         startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [.purple, .pink],
                                         startPoint: .leading, endPoint: .trailing)
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(!aiIsAvailable)
            }
            .padding(16)
        }
    }

    private var analysisSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // ── Gradient header ──────────────────────────────────
                    ZStack {
                        LinearGradient(
                            colors: [Color.purple.opacity(0.75), Color.pink.opacity(0.55)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        VStack(spacing: 8) {
                            Image(systemName: "brain.head.profile.fill")
                                .font(.system(size: 44))
                                .symbolRenderingMode(.multicolor)
                            Text("Health Briefing")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(Date().formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.vertical, 28)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // ── Content ──────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 14) {
                        if isAnalysing {
                            VStack(spacing: 20) {
                                ProgressView().scaleEffect(1.5)
                                Text("Analysing your health data…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        } else if let result = analysisResult {
                            ForEach(parsedSections(result)) { section in
                                HealthAnalysisSectionCard(title: section.title, content: section.body)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAnalysis = false }
                }
            }
        }
    }

    private struct ParsedSection: Identifiable {
        let id   = UUID()
        let title: String
        let body:  String
    }

    private func parsedSections(_ text: String) -> [ParsedSection] {
        var sections: [ParsedSection] = []
        var currentTitle = ""
        var currentLines: [String] = []

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let body = currentLines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentTitle.isEmpty || !body.isEmpty {
                    sections.append(ParsedSection(title: currentTitle, body: body))
                }
                currentTitle = String(line.dropFirst(3))
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        // Flush last section
        let lastBody = currentLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentTitle.isEmpty || !lastBody.isEmpty {
            sections.append(ParsedSection(title: currentTitle, body: lastBody))
        }
        // Fallback: if Claude returned no ## headers, show as single card
        return sections.isEmpty ? [ParsedSection(title: "", body: text)] : sections
    }

    private func analyseHealth() {
        guard let data = healthData else { return }
        analysisResult = nil
        isAnalysing    = true
        showAnalysis   = true

        Task {
            let summary = HealthService.shared.summaryText(for: data)
            do {
                let result: String
                switch aiProvider {
                case .claude:
                    result = try await ClaudeService.analyseHealthData(
                        summary:          summary,
                        age:              userAge,
                        extraInformation: userExtraInformation,
                        apiKey:           claudeApiKey
                    )
                case .appleIntelligence:
                    result = try await AppleIntelligenceService.analyseHealthData(
                        summary:          summary,
                        age:              userAge,
                        extraInformation: userExtraInformation
                    )
                }
                analysisResult = result
            } catch {
                analysisResult = "Error: \(error.localizedDescription)"
            }
            isAnalysing = false
        }
    }
}

// MARK: - Daily Brief card

private struct DailyBriefCard: View {
    let brief: DailyBrief
    let userAge: Int

    // MARK: - VO2 Max age-based reference ranges

    private var vo2Zones: (excellent: Double, average: Double) {
        switch userAge {
        case ..<30:  return (49, 39)
        case 30..<40: return (48, 35)
        case 40..<50: return (45, 31)
        case 50..<60: return (42, 27)
        default:      return (39, 23)
        }
    }

    // MARK: - Resting HR assessment

    private var restingHRAssessment: (label: String, color: Color) {
        guard let hr = brief.restingHeartRate else { return ("—", .secondary) }
        switch hr {
        case ..<50:  return ("Athlete",   .blue)
        case ..<60:  return ("Excellent", .green)
        case ..<70:  return ("Good",      .teal)
        case ..<80:  return ("Average",   .orange)
        default:     return ("Elevated",  .red)
        }
    }

    // MARK: - VO2 Max assessment

    private var vo2Assessment: (label: String, color: Color) {
        guard let v = brief.vo2MaxLatest else { return ("—", .secondary) }
        let zones = vo2Zones
        if v >= zones.excellent { return ("Excellent", .green) }
        if v >= zones.average   { return ("Above avg", .teal) }
        return ("Below avg", .orange)
    }

    // MARK: - Active energy assessment

    private let moveGoal = 600 // default kcal goal

    private var moveAssessment: (label: String, color: Color) {
        let pct = moveGoal > 0 ? (brief.activeEnergyBurnedCal * 100) / moveGoal : 0
        switch pct {
        case 100...: return ("Goal hit!",         .green)
        case 75...:  return ("\(pct)% of goal",   .teal)
        case 50...:  return ("\(pct)% of goal",   .orange)
        default:     return ("\(pct)% of goal",   .secondary)
        }
    }

    // MARK: - Insight text

    private var insightText: String? {
        var parts: [String] = []

        if let hr = brief.restingHeartRate {
            if hr < 50 {
                parts.append("Resting HR of \(hr) BPM is athlete-level.")
            } else if hr < 60 {
                parts.append("Resting HR of \(hr) BPM is excellent.")
            } else if hr >= 80 {
                parts.append("Resting HR of \(hr) BPM is elevated — consider rest and hydration.")
            }
        }

        if brief.vo2MaxSamples.count >= 2,
           let first = brief.vo2MaxSamples.first,
           let last = brief.vo2MaxSamples.last {
            let diff = last.value - first.value
            if diff < -1.0 {
                parts.append("Your VO2 Max is slightly down this month — normal variation for your age group.")
            } else if diff > 1.0 {
                parts.append("Your VO2 Max is trending up — your cardio fitness is improving.")
            } else {
                parts.append("Your VO2 Max is stable — maintaining your current fitness level.")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - VO2 trend status badge

    private var vo2TrendStatus: (label: String, color: Color) {
        guard brief.vo2MaxSamples.count >= 2,
              let first = brief.vo2MaxSamples.first,
              let last = brief.vo2MaxSamples.last else {
            return ("No data", .secondary)
        }
        let diff = last.value - first.value
        if diff > 1.0       { return ("Improving",                  .green) }
        if diff < -1.0      { return ("Declining — monitor trend",  .orange) }

        let zones = vo2Zones
        if let v = brief.vo2MaxLatest {
            if v >= zones.excellent { return ("Stable — excellent range",       .green) }
            if v >= zones.average   { return ("Stable — within normal range",   .teal) }
            return                           ("Stable — below average",         .orange)
        }
        return ("Stable", .secondary)
    }

    // MARK: - Body

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {

                // ── Header ─────────────────────────────────────────────
                HStack(alignment: .firstTextBaseline) {
                    Label("Daily Brief", systemImage: "sun.horizon.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("Morning snapshot")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // ── Top metrics row ────────────────────────────────────
                HStack(spacing: 8) {
                    briefMetric(
                        icon:   "flame.fill",
                        color:  .red,
                        value:  "\(brief.activeEnergyBurnedCal)",
                        unit:   "kcal",
                        label:  "Move",
                        badge:  moveAssessment
                    )
                    briefMetric(
                        icon:   "heart.fill",
                        color:  .pink,
                        value:  brief.restingHeartRate.map { "\($0)" } ?? "—",
                        unit:   "BPM",
                        label:  "Resting HR",
                        badge:  restingHRAssessment
                    )
                    briefMetric(
                        icon:   "lungs.fill",
                        color:  .blue,
                        value:  brief.vo2MaxLatest.map { String(format: "%.1f", $0) } ?? "—",
                        unit:   "mL/kg",
                        label:  "VO2 Max",
                        badge:  vo2Assessment
                    )
                }

                // ── Insight explainer ──────────────────────────────────
                if let insight = insightText {
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        Text(insight)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                }

                // ── VO2 Max trend ──────────────────────────────────────
                if brief.vo2MaxSamples.count >= 2 {
                    vo2TrendSection
                }

                // ── Today's workouts ───────────────────────────────────
                todayWorkoutsSection
            }
        }
    }

    // MARK: - Metric pill with badge

    @ViewBuilder
    private func briefMetric(icon: String, color: Color, value: String,
                              unit: String, label: String,
                              badge: (label: String, color: Color)) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Quality badge
            Text(badge.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(badge.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badge.color.opacity(0.12), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - VO2 Max trend with reference zones

    private var vo2TrendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("VO2 Max trend")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(vo2TrendStatus.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(vo2TrendStatus.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(vo2TrendStatus.color.opacity(0.12), in: Capsule())
            }

            let zones = vo2Zones
            let dataMin = brief.vo2MaxSamples.map(\.value).min() ?? zones.average
            let chartLo = min(dataMin, zones.average) - 3
            let chartHi = max((brief.vo2MaxSamples.map(\.value).max() ?? zones.excellent), zones.excellent) + 3

            ZStack(alignment: .trailing) {
                Chart {
                    // Excellent zone (shaded green)
                    RectangleMark(
                        yStart: .value("ExcStart", zones.excellent),
                        yEnd:   .value("ExcEnd",   chartHi)
                    )
                    .foregroundStyle(.green.opacity(0.08))

                    // Average zone (shaded blue)
                    RectangleMark(
                        yStart: .value("AvgStart", zones.average),
                        yEnd:   .value("AvgEnd",   zones.excellent)
                    )
                    .foregroundStyle(.blue.opacity(0.05))

                    // Excellent threshold line
                    RuleMark(y: .value("Excellent", zones.excellent))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                        .foregroundStyle(.green.opacity(0.5))

                    // Average threshold line
                    RuleMark(y: .value("Average", zones.average))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                        .foregroundStyle(.blue.opacity(0.4))

                    // Data line
                    ForEach(brief.vo2MaxSamples) { sample in
                        LineMark(
                            x: .value("Date",  sample.date),
                            y: .value("VO2",   sample.value)
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))

                        PointMark(
                            x: .value("Date",  sample.date),
                            y: .value("VO2",   sample.value)
                        )
                        .foregroundStyle(.blue)
                        .symbolSize(sample.id == brief.vo2MaxSamples.last?.id ? 40 : 20)
                    }
                }
                .chartYScale(domain: chartLo...chartHi)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 1)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { val in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = val.as(Double.self) {
                                Text(String(format: "%.0f", v))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 120)

                // Zone labels on the right edge
                VStack(spacing: 0) {
                    Text("Excellent")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.green)
                    Spacer()
                    Text("Average")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.blue)
                }
                .frame(height: 120)
                .padding(.trailing, 2)
            }

            // Footer explainer
            if userAge > 0 {
                Text("Shaded zone = excellent range for your age group (\(userAge)). Based on standard VO2 Max reference tables.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Today's workouts with comparison

    private var todayWorkoutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today's workouts")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if brief.workoutComparisons.isEmpty {
                    Text("Rest day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("In progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if brief.workoutComparisons.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "figure.stand")
                        .foregroundStyle(.secondary)
                    Text("No workouts logged yet today")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(Array(brief.workoutComparisons.enumerated()), id: \.element.id) { idx, comp in
                    if idx > 0 { Divider() }
                    workoutComparisonRow(comp)
                }
            }

            Divider()

            // Footer explainer
            Text("Week-on-week comparison shown at end of day.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func workoutComparisonRow(_ comp: WorkoutComparison) -> some View {
        HStack(spacing: 12) {
            // Icon in colored circle
            ZStack {
                Circle()
                    .fill(.orange.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: workoutIcon(comp.name))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.orange)
            }

            // Name + duration
            VStack(alignment: .leading, spacing: 2) {
                Text(comp.name)
                    .font(.subheadline.weight(.medium))
                Text("\(comp.todayDurationLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Calories + last week comparison
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(comp.todayCalories) kcal")
                        .font(.subheadline.weight(.semibold))
                    if let pct = comp.changePercent {
                        let color: Color = pct > 0 ? .green : pct < 0 ? .orange : .secondary
                        Text(pct == 0 ? "≈" : "\(pct > 0 ? "↑" : "↓")\(abs(pct))%")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(color)
                    }
                }
                Text("Last week: \(comp.lastWeekDurationLabel)")
                    .font(.caption2)
                    .foregroundStyle(comp.lastWeekMinutes == nil ? .tertiary : .secondary)
            }
        }
    }

    // MARK: - Helpers

    private func workoutIcon(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("walk")     { return "figure.walk" }
        if lower.contains("run")      { return "figure.run" }
        if lower.contains("hik")      { return "figure.hiking" }
        if lower.contains("cycl")     { return "figure.outdoor.cycle" }
        if lower.contains("yoga")     { return "figure.yoga" }
        if lower.contains("pilates")  { return "figure.pilates" }
        if lower.contains("core")     { return "figure.core.training" }
        if lower.contains("strength") || lower.contains("functional") { return "dumbbell" }
        if lower.contains("hiit")     { return "figure.highintensity.intervaltraining" }
        if lower.contains("swim")     { return "figure.pool.swim" }
        if lower.contains("dance")    { return "figure.dance" }
        if lower.contains("ellip")    { return "figure.elliptical" }
        if lower.contains("stair")    { return "figure.stair.stepper" }
        if lower.contains("row")      { return "figure.rowing" }
        return "figure.mixed.cardio"
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

// MARK: - ActivityCategory display helpers

private extension ActivityCategory {
    var systemImage: String {
        switch self {
        case .walking:  return "figure.walk"
        case .core:     return "figure.core.training"
        case .strength: return "dumbbell"
        case .gym:      return "figure.highintensity.intervaltraining"
        }
    }
    var color: Color {
        switch self {
        case .walking:  return .teal
        case .core:     return .purple
        case .strength: return .blue
        case .gym:      return .orange
        }
    }
}

// MARK: - Distance bar entry (used by WorkoutDistanceCard chart)

private struct DistanceBarEntry: Identifiable {
    let id     = UUID()
    let day    : String
    let series : String  // "This week" | "Last week"
    let km     : Double
}

// MARK: - Workout Distance Card

private struct WorkoutDistanceCard: View {
    let data: WeeklyDistanceData

    private var flatEntries: [DistanceBarEntry] {
        data.days.flatMap { d in [
            DistanceBarEntry(day: d.weekdayLabel, series: "This week", km: d.thisWeekKm),
            DistanceBarEntry(day: d.weekdayLabel, series: "Last week",  km: d.lastWeekKm),
        ]}
    }

    private var diffText: String {
        guard data.lastWeekTotalKm > 0.01 else { return "" }
        let diff = data.thisWeekTotalKm - data.lastWeekTotalKm
        if abs(diff) < 0.1 { return "≈ same as last week" }
        let pct = Int(abs(diff / data.lastWeekTotalKm) * 100)
        return diff > 0 ? "↑\(pct)% vs last week" : "↓\(pct)% vs last week"
    }

    private var diffColor: Color {
        data.thisWeekTotalKm >= data.lastWeekTotalKm ? .green : .orange
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ──────────────────────────────────────────────
                HStack(alignment: .firstTextBaseline) {
                    Label("Distance", systemImage: "figure.walk")
                        .font(.headline)
                        .foregroundStyle(.teal)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f km this week", data.thisWeekTotalKm))
                            .font(.subheadline.weight(.semibold))
                        if !diffText.isEmpty {
                            Text(diffText)
                                .font(.caption2)
                                .foregroundStyle(diffColor)
                        }
                    }
                }

                // ── Grouped bar chart (this week vs last week per day) ──
                Chart(flatEntries) { entry in
                    BarMark(
                        x: .value("Day", entry.day),
                        y: .value("km",  entry.km)
                    )
                    .foregroundStyle(entry.series == "This week"
                                     ? Color.teal
                                     : Color.gray.opacity(0.35))
                    .position(by: .value("Week", entry.series))
                    .cornerRadius(4)
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { val in
                        AxisGridLine()
                        AxisValueLabel {
                            if let km = val.as(Double.self) {
                                Text(String(format: "%.0fkm", km))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in AxisValueLabel() }
                }
                .frame(height: 150)

                // ── Legend ─────────────────────────────────────────────
                HStack(spacing: 16) {
                    legendSwatch(.teal,               "This week")
                    legendSwatch(.gray.opacity(0.45), "Last week")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func legendSwatch(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(colour)
                .frame(width: 14, height: 8)
            Text(label)
        }
    }
}

// MARK: - Activity Summary Card

private struct ActivitySummaryCard: View {
    let activities    : [ActivityWeekSummary]
    let weekStartDate : Date

    private var visibleActivities: [ActivityWeekSummary] {
        activities.filter { $0.thisWeekSessions > 0 || $0.lastWeekSessions > 0 }
    }

    private var weekRangeLabel: String {
        weekStartDate.formatted(.dateTime.month(.abbreviated).day()) + " – today"
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ──────────────────────────────────────────────
                HStack(alignment: .firstTextBaseline) {
                    Label("Activity", systemImage: "figure.run")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Spacer()
                    Text(weekRangeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if visibleActivities.isEmpty {
                    Text("No workouts logged this week or last week.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    ForEach(Array(visibleActivities.enumerated()), id: \.element.id) { idx, summary in
                        if idx > 0 { Divider() }
                        ActivityRow(summary: summary)
                    }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let summary: ActivityWeekSummary

    var body: some View {
        HStack(spacing: 10) {

            // ── Category icon ────────────────────────────────────────
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(summary.category.color.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: summary.category.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(summary.category.color)
            }

            // ── Name + stats ─────────────────────────────────────────
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary.category.rawValue)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    // This-week headline
                    if summary.thisWeekSessions > 0 {
                        Text("\(summary.thisWeekSessions) × \(ActivityWeekSummary.durationLabel(summary.thisWeekMinutes))")
                            .font(.caption.weight(.semibold))
                    } else {
                        Text("None this week")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Dual progress bars + delta badge
                HStack(spacing: 8) {
                    dualBars
                    Text(deltaLabel)
                        .font(.caption2)
                        .foregroundStyle(deltaColor)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // Two stacked 5pt bars: coloured = this week, gray = last week
    private var dualBars: some View {
        let maxMin   = Double(max(summary.thisWeekMinutes, summary.lastWeekMinutes, 1))
        let thisFrac = min(Double(summary.thisWeekMinutes) / maxMin, 1.0)
        let lastFrac = min(Double(summary.lastWeekMinutes) / maxMin, 1.0)

        return GeometryReader { geo in
            let w = geo.size.width
            VStack(spacing: 3) {
                ZStack(alignment: .leading) {
                    Capsule().fill(summary.category.color.opacity(0.12))
                        .frame(width: w, height: 5)
                    Capsule().fill(summary.category.color)
                        .frame(width: w * thisFrac, height: 5)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                        .frame(width: w, height: 5)
                    Capsule().fill(Color.secondary.opacity(0.35))
                        .frame(width: w * lastFrac, height: 5)
                }
            }
        }
        .frame(height: 13)
    }

    private var deltaLabel: String {
        if summary.lastWeekSessions == 0 {
            return summary.thisWeekSessions > 0 ? "new ↑" : ""
        }
        if summary.lastWeekMinutes == 0 { return "" }
        let diff = summary.thisWeekMinutes - summary.lastWeekMinutes
        if abs(diff) < 5 { return "≈ last wk" }
        let pct = Int(abs(Double(diff) / Double(summary.lastWeekMinutes)) * 100)
        return diff > 0 ? "↑\(pct)% vs last wk" : "↓\(pct)% vs last wk"
    }

    private var deltaColor: Color {
        let diff = summary.thisWeekMinutes - summary.lastWeekMinutes
        if diff >  5 { return .green }
        if diff < -5 { return .orange }
        return .secondary
    }
}

// MARK: - Health Analysis Section Card

private struct HealthAnalysisSectionCard: View {
    let title:   String
    let content: String

    private var style: (symbol: String, color: Color) {
        let t = title.lowercased()
        if t.contains("sleep")                                    { return ("moon.zzz.fill",        .indigo) }
        if t.contains("heart") || t.contains("cardio")           { return ("heart.fill",           .red)    }
        if t.contains("activity") || t.contains("exercise")      { return ("figure.run",           .orange) }
        if t.contains("distance") || t.contains("walk")          { return ("figure.walk",          .teal)   }
        if t.contains("energy") || t.contains("move")
            || t.contains("calorie")                              { return ("flame.fill",           .red)    }
        if t.contains("vo2") || t.contains("fitness")            { return ("lungs.fill",           .blue)   }
        if t.contains("recovery") || t.contains("rest")          { return ("bed.double.fill",      .blue)   }
        if t.contains("tip") || t.contains("recommend")          { return ("lightbulb.fill",       .yellow) }
        if t.contains("summary") || t.contains("overview")
            || t.contains("brief")                                { return ("chart.bar.fill",       .green)  }
        if t.contains("warning") || t.contains("concern")        { return ("exclamationmark.triangle.fill", .orange) }
        return                                                             ("sparkles",             .purple)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(style.color)
                .frame(width: 4)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                if !title.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: style.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(style.color)
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(style.color)
                    }
                }
                Text(content)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 14)
            .padding(.vertical, 14)
            .padding(.trailing, 14)
        }
        .background(style.color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Preview

#Preview {
    HealthView()
}
