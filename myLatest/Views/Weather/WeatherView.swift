//
//  WeatherView.swift
//  myLatest
//

import SwiftUI

// MARK: - Weather View

struct WeatherView: View {
    @AppStorage("claudeApiKey") private var claudeApiKey: String = ""
    @AppStorage("aiProvider") private var aiProviderRaw: String = AIProvider.appleIntelligence.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var weather = MockDataService.mockWeather()
    @State private var forecastInfo: DailyForecastInfo?
    @State private var hourlyForecast: HourlyForecastInfo?
    @State private var forecastSummary = "No forecast loaded yet."
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var statusMessage = "Tap Fetch weather to load current conditions and 7-day forecast."
    @State private var usingFallbackData = false
    @State private var isAnalysing = false
    @State private var analysisResult: String? = nil
    @State private var showAnalysis = false

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .appleIntelligence
    }
    private var aiIsAvailable: Bool {
        aiProvider == .appleIntelligence || !claudeApiKey.isEmpty
    }
    private var poweredByLabel: String {
        aiProvider == .claude ? "Powered by Claude" : "Powered by Apple Intelligence"
    }
    private var palette: ThemePalette {
        AppTheme.weather.palette(for: colorScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    fetchButton
                    statusBanner
                    WeatherCard(weather: weather, title: "Weather Stations")
                    HourlyForecastCard(hourly: hourlyForecast)
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
        .screenTheme(AppTheme.weather)
    }

    private var fetchButton: some View {
        Button(action: fetchWeather) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(Color.black.opacity(0.82)).scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(isLoading ? "Fetching..." : "Fetch weather")
            }
        }
        .buttonStyle(TransitPrimaryButtonStyle())
        .opacity(isLoading ? 0.82 : 1)
        .disabled(isLoading)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }

    private var statusBanner: some View {
        Label {
            Text(statusMessage)
        } icon: {
            Image(systemName: usingFallbackData ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(usingFallbackData ? AppTheme.warning : AppTheme.success)
        }
        .font(.transit(13, weight: .medium))
        .foregroundStyle(palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    // MARK: - Claude Weather Analysis

    private var weatherAnalyseCard: some View {
        ZStack {
            palette.mutedPanelBackground
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "cloud.sun.bolt.fill")
                        .font(.title3)
                        .symbolRenderingMode(.multicolor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AI Weather Briefing")
                            .font(.transit(18, weight: .bold))
                        Text(poweredByLabel)
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary)
                    }
                }

                if aiProvider == .claude && claudeApiKey.isEmpty {
                    Label("Add your Claude API key in Settings to enable.", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                }

                Button(action: analyseWeather) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text(hasLoaded ? "Get My Weather Briefing" : "Load forecast first")
                    }
                }
                .buttonStyle(TransitPrimaryButtonStyle())
                .opacity(!aiIsAvailable || !hasLoaded ? 0.45 : 1)
                .disabled(!aiIsAvailable || !hasLoaded)
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
                        palette.buttonBackground
                        VStack(spacing: 8) {
                            Image(systemName: "cloud.sun.bolt.fill")
                                .font(.system(size: 44))
                                .symbolRenderingMode(.multicolor)
                            Text("Weather Briefing")
                                .font(.transit(30, weight: .heavy))
                                .foregroundStyle(palette.buttonForeground)
                            Text(Date().formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(palette.buttonForeground.opacity(0.72))
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

    private func analyseWeather() {
        analysisResult = nil
        isAnalysing    = true
        showAnalysis   = true

        Task {
            do {
                let result: String
                switch aiProvider {
                case .claude:
                    result = try await ClaudeService.analyseWeather(
                        forecastSummary: forecastSummary,
                        apiKey: claudeApiKey
                    )
                case .appleIntelligence:
                    result = try await AppleIntelligenceService.analyseWeather(
                        forecastSummary: forecastSummary
                    )
                }
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
            hourlyForecast = bundle.hourlyForecast
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

struct WeatherAnalysisSectionCard: View {
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
