//
//  ContentView.swift
//  myLatest
//

import SwiftUI
import Charts

// MARK: - Load State

enum LoadState {
    case idle
    case loading
    case loaded(DashboardData)

    var data: DashboardData? {
        if case .loaded(let d) = self { return d }
        return nil
    }
    var isIdle:    Bool { if case .idle    = self { return true }; return false }
    var isLoading: Bool { if case .loading = self { return true }; return false }
    var isLoaded:  Bool { if case .loaded  = self { return true }; return false }
    var shouldRedact: Bool { !isLoaded }
}

// MARK: - Placeholder data (drives card layout before first real fetch)

private extension DashboardData {
    static func placeholder(trainLineName: String,
                            homeStation: String,
                            cityStation: String) -> DashboardData {
        let now = Date()
        let cal = Calendar.current
        let base = TrainService.secondsSinceMidnight()

        return DashboardData(
            weather: WeatherInfo(
                stationName: "Nearest station",
                observations: [
                    WeatherObservation(localDateTime: "11:30am", apparentTemp: 17.4, airTemp: 18.8,
                                       relHumidity: 81, cloud: "Partly Cloudy",  windDir: "SW", windSpeedKmh: 17),
                    WeatherObservation(localDateTime: "11:00am", apparentTemp: 16.8, airTemp: 17.9,
                                       relHumidity: 83, cloud: "Mostly Cloudy",  windDir: "SW", windSpeedKmh: 19),
                    WeatherObservation(localDateTime: "10:30am", apparentTemp: 15.9, airTemp: 17.1,
                                       relHumidity: 85, cloud: "Cloudy",         windDir: "SW", windSpeedKmh: 15),
                    WeatherObservation(localDateTime: "10:00am", apparentTemp: 14.2, airTemp: 15.5,
                                       relHumidity: 88, cloud: "Overcast",       windDir: "S",  windSpeedKmh: 11),
                    WeatherObservation(localDateTime:  "9:30am", apparentTemp: 13.1, airTemp: 14.4,
                                       relHumidity: 89, cloud: "Overcast",       windDir: "S",  windSpeedKmh:  9),
                ]
            ),
            upcomingEvents: [
                CalendarEvent(title: "Morning team standup",       date: cal.date(byAdding: .hour, value: 1, to: now)!,
                              durationMinutes: 30, location: "Video call",        isAllDay: false),
                CalendarEvent(title: "Product review meeting",     date: cal.date(byAdding: .hour, value: 3, to: now)!,
                              durationMinutes: 60, location: "Conference Room B", isAllDay: false),
                CalendarEvent(title: "End of sprint retrospective",date: cal.date(byAdding: .hour, value: 5, to: now)!,
                              durationMinutes: 45, location: nil,                 isAllDay: false),
            ],
            trainInfo: TrainInfo(
                lineName:             trainLineName.isEmpty ? "Your train line" : trainLineName,
                serviceIsGood:        true,
                serviceStatusMessage: "Live service status will appear here.",
                alerts:               [],
                plannedWorks:         [
                    TrainPlannedWork(id: 1, title: "Placeholder planned works entry",
                                    link: "", type: "works", upcomingCurrent: "Upcoming",
                                    affectedStations: [])
                ],
                homeStationName:       homeStation.isEmpty ? "Home station" : homeStation,
                cityStationName:       cityStation.isEmpty ? "Flinders Street" : cityStation,
                homeStationDepartures: placeholderDepartures(base: base + 300),
                cityStationDepartures: placeholderDepartures(base: base + 600),
                melbourneTimeAtFetch:  "--:-- --"
            ),
            fetchedAt: now
        )
    }

    private static func placeholderDepartures(base: Int) -> [TrainDeparture] {
        (0..<4).map { i in
            let t = TrainService.secondsToTimeString(base + i * 600)
            return TrainDeparture(station: "", isToCity: true,
                                  scheduledTimeStr: t,
                                  estimatedArrivalStr: t, estimatedDepartureStr: t,
                                  estimatedDepartureSeconds: 0,
                                  platform: "1", estimatedPlatform: "1")
        }
    }
}

// MARK: - Root View

struct ContentView: View {
    @AppStorage("trainLineName") private var trainLineName: String = ""
    @AppStorage("homeStation")   private var homeStation:   String = ""
    @AppStorage("cityStation")   private var cityStation:   String = "Flinders Street"

    @State private var loadState: LoadState = .idle
    @State private var showSettings = false

    private var displayData: DashboardData {
        loadState.data ?? .placeholder(trainLineName: trainLineName,
                                       homeStation:   homeStation,
                                       cityStation:   cityStation)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    fetchButton
                    statusBanner
                    cardsStack
                }
                .padding()
            }
            .refreshable { await performFetch() }
            .navigationTitle("My Latest")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(trainLineName: $trainLineName)
            }
        }
    }

    // MARK: - Fetch button

    private var fetchButton: some View {
        Button(action: fetchData) {
            HStack(spacing: 8) {
                if loadState.isLoading {
                    ProgressView().tint(.white).scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(loadState.isLoading ? "Fetching…" : "Fetch my latest")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(loadState.isLoading ? Color.accentColor.opacity(0.7) : Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(loadState.isLoading)
        .animation(.easeInOut(duration: 0.2), value: loadState.isLoading)
    }

    // MARK: - Status banner

    @ViewBuilder
    private var statusBanner: some View {
        switch loadState {
        case .idle:
            Label {
                Text("Tap **Fetch my latest** to load your dashboard")
            } icon: {
                Image(systemName: "hand.tap")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .transition(.opacity)

        case .loading:
            EmptyView()

        case .loaded(let data):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Last updated at \(data.fetchedAt.formatted(date: .omitted, time: .shortened))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Cards stack (always visible; redacted until data arrives)

    private var cardsStack: some View {
        VStack(spacing: 20) {
            TrainCard(train: displayData.trainInfo)
            CalendarCard(events: displayData.upcomingEvents)
            
        }
        .redacted(reason: loadState.shouldRedact ? .placeholder : [])
        .opacity(loadState.isIdle ? 0.55 : 1.0)
        .animation(.spring(duration: 0.45), value: loadState.isLoaded)
    }

    // MARK: - Action

    /// Called by the fetch button (non-async context).
    private func fetchData() {
        Task { await performFetch() }
    }

    /// Shared async implementation — used by both the button and pull-to-refresh.
    private func performFetch() async {
        guard !loadState.isLoading else { return }

        // On the very first fetch (idle state) show the skeleton/placeholder cards
        // so the layout doesn't jump. On subsequent refreshes (data already on screen)
        // keep the existing data visible and silently swap in the new data when it
        // arrives — the pull-to-refresh spinner provides all the visual feedback needed.
        let previousState = loadState
        if !loadState.isLoaded {
            withAnimation { loadState = .loading }
        }
        do {
            let data = try await MockDataService.shared.fetchDashboard(
                trainLineName: trainLineName,
                homeStation:   homeStation,
                cityStation:   cityStation,
                includeWeather: false
            )
            withAnimation(.spring(duration: 0.5)) {
                loadState = .loaded(data)
            }
        } catch is CancellationError {
            withAnimation {
                loadState = previousState
            }
        } catch {
            print("⚠️ Dashboard fetch failed unexpectedly (\(error.localizedDescription))")
            withAnimation {
                loadState = previousState
            }
        }
    }
}

// MARK: - Weather View

struct WeatherView: View {
    @AppStorage("claudeApiKey") private var claudeApiKey: String = ""
    @State private var weather = MockDataService.mockWeather()
    @State private var forecastInfo: DailyForecastInfo?
    @State private var forecastSummary = "No forecast loaded yet."
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var statusMessage = "Tap Fetch weather to load current conditions and 7-day forecast."
    @State private var usingFallbackData = false
    @State private var isAnalysing = false
    @State private var analysisResult: String? = nil
    @State private var showAnalysis = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    fetchButton
                    statusBanner
                    WeatherCard(weather: weather, title: "Weather Stations")
                    ForecastCard(forecast: forecastInfo, debugSummary: forecastSummary)
                    weatherAnalyseCard
                }
                .padding()
            }
            .refreshable { await performFetch() }
            .navigationTitle("Weather")
            .task {
                guard !hasLoaded else { return }
                await performFetch()
            }
            .sheet(isPresented: $showAnalysis) { analysisSheet }
        }
    }

    private var fetchButton: some View {
        Button(action: fetchWeather) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(.white).scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(isLoading ? "Fetching..." : "Fetch weather")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(isLoading ? Color.accentColor.opacity(0.7) : Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isLoading)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }

    private var statusBanner: some View {
        Label {
            Text(statusMessage)
        } icon: {
            Image(systemName: usingFallbackData ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(usingFallbackData ? .orange : .green)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    // MARK: - Claude Weather Analysis

    private var weatherAnalyseCard: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.18), Color.indigo.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "cloud.sun.bolt.fill")
                        .font(.title3)
                        .symbolRenderingMode(.multicolor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AI Weather Briefing")
                            .font(.headline)
                        Text("Powered by Claude")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if claudeApiKey.isEmpty {
                    Label("Add your Claude API key in Settings to enable.", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(action: analyseWeatherWithClaude) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text(hasLoaded ? "Get My Weather Briefing" : "Load forecast first")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        claudeApiKey.isEmpty || !hasLoaded
                        ? LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.25)],
                                         startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [.blue, .indigo],
                                         startPoint: .leading, endPoint: .trailing)
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(claudeApiKey.isEmpty || !hasLoaded)
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
                            colors: [Color.blue.opacity(0.75), Color.indigo.opacity(0.55)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        VStack(spacing: 8) {
                            Image(systemName: "cloud.sun.bolt.fill")
                                .font(.system(size: 44))
                                .symbolRenderingMode(.multicolor)
                            Text("Weather Briefing")
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
                                Text("Analysing your forecast…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        } else if let result = analysisResult {
                            ForEach(weatherParsedSections(result)) { section in
                                WeatherAnalysisSectionCard(title: section.title, content: section.body)
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

    private struct WeatherParsedSection: Identifiable {
        let id    = UUID()
        let title: String
        let body:  String
    }

    private func weatherParsedSections(_ text: String) -> [WeatherParsedSection] {
        var sections: [WeatherParsedSection] = []
        var currentTitle = ""
        var currentLines: [String] = []

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let body = currentLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentTitle.isEmpty || !body.isEmpty {
                    sections.append(WeatherParsedSection(title: currentTitle, body: body))
                }
                currentTitle = String(line.dropFirst(3))
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        let lastBody = currentLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentTitle.isEmpty || !lastBody.isEmpty {
            sections.append(WeatherParsedSection(title: currentTitle, body: lastBody))
        }
        return sections.isEmpty ? [WeatherParsedSection(title: "", body: text)] : sections
    }

    private func analyseWeatherWithClaude() {
        analysisResult = nil
        isAnalysing    = true
        showAnalysis   = true

        Task {
            do {
                let result = try await ClaudeService.analyseWeather(
                    forecastSummary: forecastSummary,
                    apiKey: claudeApiKey
                )
                analysisResult = result
            } catch {
                analysisResult = "Error: \(error.localizedDescription)"
            }
            isAnalysing = false
        }
    }

    private func fetchWeather() {
        Task { await performFetch() }
    }

    private func performFetch() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let bundle = try await WeatherService.shared.fetchWeatherBundle()
            weather = bundle.weather
            if let forecast = bundle.forecast {
                forecastInfo = forecast
                forecastSummary = forecast.debugSummary(limit: 7)
                print("🌤️ 7-day forecast (\(forecast.locationName), \(forecast.geohash))")
                print(forecastSummary)
            } else {
                forecastInfo = nil
                forecastSummary = "Forecast unavailable for current location."
            }
            let stamp = Date().formatted(date: .omitted, time: .shortened)
            statusMessage = "Last updated at \(stamp)"
            usingFallbackData = false
            hasLoaded = true   // only mark loaded on success so cancelled tasks can retry
        } catch is CancellationError {
            // Task was cancelled (e.g. user switched tabs mid-fetch) — leave state unchanged.
            return
        } catch {
            // On first-ever load, show mock data so the cards aren't blank.
            // On subsequent refreshes, keep the last real data instead of replacing
            // it with stale mock values.
            if !hasLoaded {
                weather = MockDataService.mockWeather()
                forecastInfo = nil
            }
            forecastSummary = "Forecast unavailable (\(error.localizedDescription))"
            statusMessage = "Refresh failed: \(error.localizedDescription)"
            usingFallbackData = true
        }
    }
}

// MARK: - Weather Analysis Section Card

private struct WeatherAnalysisSectionCard: View {
    let title:   String
    let content: String

    private var style: (symbol: String, color: Color) {
        let t = title.lowercased()
        if t.contains("today")                          { return ("sun.max.fill",          .orange) }
        if t.contains("commute") || t.contains("train") { return ("tram.fill",              .blue)   }
        if t.contains("week") || t.contains("ahead")   { return ("calendar",               .indigo) }
        if t.contains("tip")                            { return ("lightbulb.fill",         .yellow) }
        if t.contains("fire")                           { return ("flame.fill",             .red)    }
        if t.contains("rain") || t.contains("storm")   { return ("cloud.rain.fill",        .cyan)   }
        if t.contains("wind")                           { return ("wind",                   .teal)   }
        return                                                   ("sparkles",               .purple)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Colored left accent bar
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

// MARK: - Weather Card

struct WeatherCard: View {
    let weather: WeatherInfo
    var title: String = "Weather"

    private var latest: WeatherObservation? { weather.observations.first }
    /// Reversed so the chart displays oldest → newest left to right.
    private var chartObs: [WeatherObservation] { Array(weather.observations.reversed()) }

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
                    temperatureChart
                }
            }
        }
    }

    // MARK: - Observation chart

    private var temperatureChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent observations")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)

            Chart {
                ForEach(chartObs) { obs in
                    AreaMark(
                        x: .value("Time", obs.localDateTime),
                        y: .value("Feels like", obs.apparentTemp)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        .linearGradient(
                            Gradient(colors: [.blue.opacity(0.3), .blue.opacity(0.04)]),
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", obs.localDateTime),
                        y: .value("Feels like", obs.apparentTemp)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    PointMark(
                        x: .value("Time", obs.localDateTime),
                        y: .value("Feels like", obs.apparentTemp)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(25)

                    LineMark(
                        x: .value("Time", obs.localDateTime),
                        y: .value("Air temp", obs.airTemp)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel().font(.caption2)
                }
            }
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
            .frame(height: 110)

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Capsule().fill(.blue).frame(width: 16, height: 3)
                    Text("Feels like").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Capsule().fill(.orange.opacity(0.8)).frame(width: 16, height: 2)
                    Text("Air temp").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ForecastCard: View {
    let forecast: DailyForecastInfo?
    let debugSummary: String

    @State private var selectedDayId: String?

    private var days: [DailyForecastDay] { forecast.map { Array($0.days.prefix(7)) } ?? [] }
    private var weekMin: Int { days.compactMap(\.tempMin).min() ?? 0 }
    private var weekMax: Int { days.compactMap(\.tempMax).max() ?? 40 }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                Label("7-Day Forecast", systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let forecast {
                    Text(forecast.locationName)
                        .font(.subheadline.weight(.medium))

                    Divider()

                    // ── Horizontal 7-day strip ──────────────────────────
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 2) {
                            ForEach(days) { day in
                                ForecastDayColumn(
                                    day: day,
                                    weekMin: weekMin,
                                    weekMax: weekMax,
                                    isSelected: selectedDayId == day.id
                                )
                                .onTapGesture {
                                    withAnimation(.spring(duration: 0.25)) {
                                        selectedDayId = selectedDayId == day.id ? nil : day.id
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }

                    // ── Rain chance bar chart ────────────────────────────
                    if days.contains(where: { $0.rainChancePercent != nil }) {
                        Divider()
                        rainChanceChart
                    }

                    // ── Expanded day detail ──────────────────────────────
                    if let id = selectedDayId,
                       let day = days.first(where: { $0.id == id }) {
                        Divider()
                        ForecastSelectedDayDetail(day: day)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                } else {
                    Text(debugSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Debug summary") {
                    Text(debugSummary)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Rain chance bar chart

    private var rainChanceChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rain chance (%)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)

            Chart {
                ForEach(days) { day in
                    BarMark(
                        x: .value("Day", shortDayLabel(day.date)),
                        y: .value("Chance", day.rainChancePercent ?? 0)
                    )
                    .foregroundStyle(rainBarColor(for: day.rainChancePercent ?? 0))
                    .cornerRadius(4)
                }
                RuleMark(y: .value("50%", 50))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.blue.opacity(0.4))
                    .annotation(position: .leading) {
                        Text("50").font(.caption2).foregroundStyle(.blue.opacity(0.4))
                    }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)%").font(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.caption2) }
            }
            .frame(height: 80)
        }
    }

    private func rainBarColor(for chance: Int) -> LinearGradient {
        let opacity = 0.3 + 0.7 * Double(chance) / 100
        return LinearGradient(
            colors: [.blue.opacity(opacity), .blue.opacity(opacity * 0.6)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private func shortDayLabel(_ isoDate: String) -> String {
        let inFmt = DateFormatter()
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.dateFormat = "yyyy-MM-dd"
        let outFmt = DateFormatter()
        outFmt.dateFormat = "EEE"
        if let d = inFmt.date(from: isoDate) { return outFmt.string(from: d) }
        return String(isoDate.prefix(3))
    }
}

// MARK: - Forecast Day Column (horizontal strip cell)

private struct ForecastDayColumn: View {
    let day: DailyForecastDay
    let weekMin: Int
    let weekMax: Int
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Text(shortDayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)

            Image(systemName: conditionSymbol)
                .font(.system(size: 20))
                .symbolRenderingMode(.multicolor)
                .frame(height: 24)

            // Rain % — placeholder space when absent to keep columns aligned
            Group {
                if let rain = day.rainChancePercent, rain > 10 {
                    Text("\(rain)%").foregroundStyle(.blue)
                } else {
                    Text(" ")
                }
            }
            .font(.caption2)

            // Vertical temperature range bar
            TempRangeBar(tempMin: day.tempMin, tempMax: day.tempMax,
                         weekMin: weekMin, weekMax: weekMax)
                .frame(width: 6, height: 44)

            VStack(spacing: 1) {
                Text(day.tempMax.map { "\($0)°" } ?? "--")
                    .font(.caption2.weight(.semibold))
                Text(day.tempMin.map { "\($0)°" } ?? "--")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 46)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    private var shortDayName: String {
        let inFmt = DateFormatter()
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.dateFormat = "yyyy-MM-dd"
        let outFmt = DateFormatter()
        outFmt.dateFormat = "EEE"
        if let d = inFmt.date(from: day.date) { return outFmt.string(from: d) }
        return day.date
    }

    private var conditionSymbol: String {
        let text = day.shortText?.lowercased() ?? ""
        if text.contains("storm") || text.contains("thunder") { return "cloud.bolt.rain.fill" }
        if text.contains("shower")                             { return "cloud.rain.fill" }
        if text.contains("rain") || text.contains("drizzle")  { return "cloud.drizzle.fill" }
        if text.contains("snow")                               { return "snowflake" }
        if text.contains("fog") || text.contains("mist")      { return "cloud.fog.fill" }
        if text.contains("partly")                             { return "cloud.sun.fill" }
        if text.contains("overcast") || text.contains("cloud"){ return "cloud.fill" }
        if text.contains("sunny") || text.contains("fine") || text.contains("clear") { return "sun.max.fill" }
        if let rain = day.rainChancePercent {
            if rain >= 70 { return "cloud.rain.fill" }
            if rain >= 40 { return "cloud.sun.rain.fill" }
        }
        return "sun.max.fill"
    }
}

// MARK: - Vertical temperature range bar

private struct TempRangeBar: View {
    let tempMin: Int?
    let tempMax: Int?
    let weekMin: Int
    let weekMax: Int

    var body: some View {
        GeometryReader { geo in
            let range = max(Double(weekMax - weekMin), 1)
            let lo    = Double((tempMin ?? weekMin) - weekMin) / range
            let hi    = Double((tempMax ?? weekMax) - weekMin) / range
            let h     = geo.size.height
            let topGap = h * (1.0 - hi)
            let barH   = max(h * (hi - lo), 4.0)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [.orange, .blue],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: barH)
                    .offset(y: topGap)
            }
        }
    }
}

// MARK: - Expanded day detail (shown on tap)

private struct ForecastSelectedDayDetail: View {
    let day: DailyForecastDay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(formattedDay(day.date))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(temperatureText)
                    .font(.subheadline.weight(.semibold))
            }

            if let text = day.shortText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Text(text).font(.caption).foregroundStyle(.primary)
            }

            HStack(spacing: 10) {
                StatPill(label: "Rain", value: rainText, symbol: "cloud.rain.fill")
                if let uv = day.uvCategory?.trimmingCharacters(in: .whitespacesAndNewlines), !uv.isEmpty {
                    StatPill(label: "UV", value: uv, symbol: "sun.max.fill")
                }
                if let fire = day.fireDanger?.trimmingCharacters(in: .whitespacesAndNewlines), !fire.isEmpty {
                    StatPill(label: "Fire", value: fire, symbol: "flame.fill")
                }
            }

            if let detail = day.extendedText?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var temperatureText: String {
        switch (day.tempMin, day.tempMax) {
        case let (min?, max?): return "\(min)-\(max)°C"
        case let (nil, max?): return "max \(max)°C"
        case let (min?, nil): return "min \(min)°C"
        case (nil, nil): return "n/a"
        }
    }

    private var rainText: String {
        let chance = day.rainChancePercent.map { "\($0)%" } ?? "n/a"
        guard let min = day.rainAmountMinMm else { return chance }
        guard let max = day.rainAmountMaxMm else {
            return min > 0 ? "\(chance) (\(min)mm)" : chance
        }
        if max > 0 { return "\(chance) (\(min)-\(max)mm)" }
        return chance
    }

    private func formattedDay(_ isoDate: String) -> String {
        let inFmt = DateFormatter()
        inFmt.calendar = Calendar(identifier: .gregorian)
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.dateFormat = "yyyy-MM-dd"
        let outFmt = DateFormatter()
        outFmt.calendar = Calendar.current
        outFmt.locale = Locale.current
        outFmt.dateFormat = "EEEE d MMM"
        if let d = inFmt.date(from: isoDate) { return outFmt.string(from: d) }
        return isoDate
    }
}

private struct StatPill: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text("\(label): \(value)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

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

struct EventRow: View {
    let event: CalendarEvent
    @Environment(\.openURL) private var openURL
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
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(timeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let location = event.location {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

// MARK: - Train Card

struct TrainCard: View {
    let train: TrainInfo
    @State private var showPlannedWorks = false

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ────────────────────────────────────────────────
                HStack {
                    Label("Train Status", systemImage: "tram.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(train.melbourneTimeAtFetch, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // ── Line name + service status ────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text(train.lineName)
                        .font(.subheadline.weight(.semibold))

                    if train.serviceIsGood {
                        Label(train.serviceStatusMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .lineLimit(2)
                    } else {
                        ForEach(train.alerts) { alert in
                            TrainAlertRow(alert: alert)
                        }
                        if train.alerts.isEmpty {
                            Text(train.serviceStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                // ── Home station departures ───────────────────────────────
                if !train.homeStationName.isEmpty {
                    Divider()
                    DepartureSectionView(stationName:      train.homeStationName,
                                        departures:       train.homeStationDepartures,
                                        splitByDirection: true)
                }

                // ── City station departures ───────────────────────────────
                if !train.cityStationName.isEmpty {
                    Divider()
                    DepartureSectionView(stationName:      train.cityStationName,
                                        departures:       train.cityStationDepartures,
                                        splitByDirection: false)
                }

                // ── Planned works (collapsible) ───────────────────────────
                if !train.plannedWorks.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $showPlannedWorks) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(train.plannedWorks) { work in
                                TrainPlannedWorkRow(work: work)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Label("Planned Works (\(train.plannedWorks.count))",
                              systemImage: "wrench.and.screwdriver")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Train Alert Row

struct TrainAlertRow: View {
    let alert: TrainServiceAlert

    private var alertColor: Color {
        switch alert.alertType.lowercased() {
        case "major": return .red
        case "minor": return .orange
        default:      return .yellow
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(alertColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                if let mins = alert.additionalTravelMinutes, mins > 0 {
                    Text("Allow +\(mins) min")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(alertColor)
                }
                if let due = alert.disruptionDueTo {
                    Text("Due to \(due)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(alert.plainText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Departure Section

struct DepartureSectionView: View {
    let stationName: String
    let departures: [TrainDeparture]
    /// When true the list is split into separate Inbound / Outbound sub-sections.
    var splitByDirection: Bool = false

    private var inbound:  [TrainDeparture] { departures.filter {  $0.isToCity } }
    private var outbound: [TrainDeparture] { departures.filter { !$0.isToCity } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack(spacing: 5) {
                Image(systemName: "mappin.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text("From \(stationName)")
                    .font(.caption.weight(.semibold))
            }

            if splitByDirection {
                directionSubSection(label:  "Inbound → City",
                                    color:  .blue,
                                    symbol: "arrow.up.circle.fill",
                                    rows:   inbound)
                directionSubSection(label:  "Outbound → Home",
                                    color:  .orange,
                                    symbol: "arrow.down.circle.fill",
                                    rows:   outbound)
            } else {
                if departures.isEmpty {
                    Text("No upcoming departures found")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    departureTable(departures)
                }
            }
        }
    }

    // MARK: Sub-section for one direction

    @ViewBuilder
    private func directionSubSection(label: String,
                                     color: Color,
                                     symbol: String,
                                     rows: [TrainDeparture]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(label)
                    .foregroundStyle(color)
            }
            .font(.caption2.weight(.semibold))

            if rows.isEmpty {
                Text("No upcoming trains")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .padding(.leading, 4)
            } else {
                departureTable(rows)
            }
        }
    }

    // MARK: Shared table renderer

    private func departureTable(_ rows: [TrainDeparture]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            // Column headers
            GridRow {
                Text("Time")    .gridColumnAlignment(.leading)
                Text("Plat")    .gridColumnAlignment(.center)
                Text("ETA")     .gridColumnAlignment(.leading)
                Text("ETD")     .gridColumnAlignment(.leading)
                Text("Dir")     .gridColumnAlignment(.leading)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)

            // One row per departure
            ForEach(rows) { dep in
                GridRow {
                    Text(dep.scheduledTimeStr)
                    Text(dep.estimatedPlatform).frame(maxWidth: .infinity, alignment: .center)
                    Text(dep.estimatedArrivalStr)
                    Text(dep.estimatedDepartureStr)
                    directionView(dep.isToCity)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func directionView(_ isToCity: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: isToCity ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(isToCity ? Color.blue : Color.orange)
            Text(isToCity ? "In" : "Out")
        }
        .font(.caption2)
    }
}

// MARK: - Planned Work Row

struct TrainPlannedWorkRow: View {
    let work: TrainPlannedWork
    @Environment(\.openURL) private var openURL

    private var badge: (text: String, color: Color) {
        work.upcomingCurrent.lowercased() == "current"
            ? ("Current",  .orange)
            : ("Upcoming", .blue)
    }

    var body: some View {
        Button {
            if let url = URL(string: work.link), !work.link.isEmpty { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(badge.text)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badge.color.opacity(0.15))
                    .foregroundStyle(badge.color)
                    .clipShape(Capsule())

                VStack(alignment: .leading, spacing: 2) {
                    Text(work.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !work.affectedStations.isEmpty {
                        Text(work.affectedStations.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if !work.link.isEmpty {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card Container

struct CardContainer<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Binding var trainLineName: String
    @AppStorage("homeStation") private var homeStation: String = ""
    @AppStorage("cityStation") private var cityStation: String = "Flinders Street"

    @Environment(\.dismiss) private var dismiss
    @Environment(WeatherStationStore.self) private var stationStore
    @AppStorage("claudeApiKey") private var claudeApiKey: String = ""
    @AppStorage("userAge")      private var userAge:      String = ""

    var body: some View {
        NavigationStack {
            Form {
                // ── Train ────────────────────────────────────────────────
                Section {
                    LabeledContent("Line") {
                        TextField("e.g. Alamein", text: $trainLineName)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Home Station") {
                        TextField("e.g. Willison", text: $homeStation)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("City Station") {
                        TextField("e.g. Flinders Street", text: $cityStation)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Train")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("**Line** — the Metro Trains Melbourne line name (e.g. Alamein, Belgrave, Craigieburn).", systemImage: "tram.fill")
                        Label("**Home Station** — your local station for outbound departures.", systemImage: "house.fill")
                        Label("**City Station** — your city terminus, defaults to Flinders Street.", systemImage: "building.2.fill")
                        Text("Names are matched case-insensitively. Partial names accepted (e.g. \"Flinders\" matches \"Flinders Street\").")
                            .padding(.top, 2)
                    }
                    .font(.footnote)
                }

                // ── Profile ──────────────────────────────────────────────
                Section {
                    LabeledContent("Age") {
                        TextField("e.g. 35", text: $userAge)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Used to personalise your AI health analysis.")
                }

                // ── Claude AI ─────────────────────────────────────────────
                Section {
                    LabeledContent("API Key") {
                        TextField("sk-ant-...", text: $claudeApiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Claude AI")
                } footer: {
                    Text("Your Anthropic API key for health analysis. Get one at console.anthropic.com.")
                }

                // ── Weather Stations ─────────────────────────────────────
                Section {
                    NavigationLink {
                        WeatherStationsView()
                    } label: {
                        HStack {
                            Text("Weather Stations")
                            Spacer()
                            Text("\(stationStore.all.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Weather")
                } footer: {
                    Text("The nearest station to your device is chosen automatically. Add custom BOM stations here.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Idle — first launch") {
    ContentView()
}

#Preview("Loaded — real-looking data") {
    let weather = MockDataService.mockWeather()
    let events  = MockDataService.mockEvents()
    let train   = MockDataService.mockTrainInfo()
    let data    = DashboardData(weather: weather, upcomingEvents: events,
                                trainInfo: train, fetchedAt: Date())
    _LoadedPreview(data: data)
}

private struct _LoadedPreview: View {
    let data: DashboardData
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    CalendarCard(events: data.upcomingEvents)
                    TrainCard(train: data.trainInfo)
                }
                .padding()
            }
            .navigationTitle("My Latest")
        }
    }
}
