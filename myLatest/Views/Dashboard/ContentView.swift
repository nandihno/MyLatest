//
//  ContentView.swift
//  myLatest
//

import SwiftUI

// MARK: - Placeholder data (drives card layout before first real fetch)

extension DashboardData {
    static func placeholder(trainLineName: String,
                            homeStation: String,
                            cityStation: String,
                            drivingDestinations: [DrivingDestination]) -> DashboardData {
        let now = Date()
        let cal = Calendar.current
        let base = TrainService.secondsSinceMidnight()

        return DashboardData(
            weather: WeatherInfo(
                stationName: "Nearest station",
                observations: [
                    WeatherObservation(localDateTime: "11:30am", apparentTemp: 17.4, airTemp: 18.8,
                                       pressureMSL: 1011.8, relHumidity: 81, cloud: "Partly Cloudy",  windDir: "SW", windSpeedKmh: 17),
                    WeatherObservation(localDateTime: "11:00am", apparentTemp: 16.8, airTemp: 17.9,
                                       pressureMSL: 1012.0, relHumidity: 83, cloud: "Mostly Cloudy",  windDir: "SW", windSpeedKmh: 19),
                    WeatherObservation(localDateTime: "10:30am", apparentTemp: 15.9, airTemp: 17.1,
                                       pressureMSL: 1012.2, relHumidity: 85, cloud: "Cloudy",         windDir: "SW", windSpeedKmh: 15),
                    WeatherObservation(localDateTime: "10:00am", apparentTemp: 15.1, airTemp: 16.3,
                                       pressureMSL: 1012.5, relHumidity: 86, cloud: "Cloudy",         windDir: "S",  windSpeedKmh: 13),
                    WeatherObservation(localDateTime:  "9:30am", apparentTemp: 14.5, airTemp: 15.6,
                                       pressureMSL: 1012.8, relHumidity: 88, cloud: "Overcast",       windDir: "S",  windSpeedKmh: 11),
                    WeatherObservation(localDateTime:  "9:00am", apparentTemp: 13.9, airTemp: 15.0,
                                       pressureMSL: 1013.0, relHumidity: 89, cloud: "Overcast",       windDir: "S",  windSpeedKmh: 10),
                    WeatherObservation(localDateTime:  "8:30am", apparentTemp: 13.4, airTemp: 14.5,
                                       pressureMSL: 1013.2, relHumidity: 90, cloud: "Cloudy",         windDir: "SE", windSpeedKmh:  9),
                    WeatherObservation(localDateTime:  "8:00am", apparentTemp: 12.9, airTemp: 14.0,
                                       pressureMSL: 1013.5, relHumidity: 91, cloud: "Cloudy",         windDir: "SE", windSpeedKmh:  8),
                    WeatherObservation(localDateTime:  "7:30am", apparentTemp: 12.5, airTemp: 13.6,
                                       pressureMSL: 1013.7, relHumidity: 92, cloud: "Mostly Cloudy",  windDir: "E",  windSpeedKmh:  8),
                    WeatherObservation(localDateTime:  "7:00am", apparentTemp: 12.0, airTemp: 13.1,
                                       pressureMSL: 1013.9, relHumidity: 93, cloud: "Mostly Cloudy",  windDir: "E",  windSpeedKmh:  7),
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
                homeStationAllDepartures: placeholderDepartures(base: base + 300),
                cityStationDepartures: placeholderDepartures(base: base + 600),
                cityStationAllDepartures: placeholderDepartures(base: base + 600),
                melbourneTimeAtFetch:  "--:-- --"
            ),
            busInfo: nil,
            drivingEstimates: MockDataService.mockDrivingTimes(for: drivingDestinations),
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
    @AppStorage("googleMapsApiKey") private var googleMapsApiKey: String = ""
    @AppStorage("drivingProvider") private var drivingProviderRaw: String = DrivingProvider.apple.rawValue
    @AppStorage("transportMode") private var transportModeRaw: String = TransportMode.victorian.rawValue

    @Environment(DrivingDestinationStore.self) private var drivingDestinationStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadState: LoadState = .idle
    @State private var showSettings = false

    private var drivingProvider: DrivingProvider {
        DrivingProvider(rawValue: drivingProviderRaw) ?? .apple
    }

    private var transportMode: TransportMode {
        TransportMode(rawValue: transportModeRaw) ?? .victorian
    }

    private var displayData: DashboardData {
        loadState.data ?? .placeholder(trainLineName: trainLineName,
                                       homeStation:   homeStation,
                                       cityStation:   cityStation,
                                       drivingDestinations: drivingDestinationStore.all)
    }
    private var palette: ThemePalette {
        AppTheme.transport.palette(for: colorScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    fetchButton
                    statusBanner
                    gtfsProgressBanner
                    cardsStack
                }
                .padding()
            }
            .refreshable { await performFetch() }
            .navigationTitle("My Latest")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(trainLineName: $trainLineName)
            }
        }
        .screenTheme(AppTheme.transport)
    }

    // MARK: - Fetch button

    private var fetchButton: some View {
        Button(action: fetchData) {
            HStack(spacing: 8) {
                if loadState.isLoading {
                    ProgressView().tint(Color.black.opacity(0.82)).scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(loadState.isLoading ? "Fetching…" : "Fetch my latest")
            }
        }
        .buttonStyle(TransitPrimaryButtonStyle())
        .opacity(loadState.isLoading ? 0.82 : 1)
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
            .font(.transit(13, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .transition(.opacity)

        case .loading:
            EmptyView()

        case .loaded(let data):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.success)
                Text("Last updated at \(data.fetchedAt.formatted(date: .omitted, time: .shortened))")
            }
            .font(.transit(12, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - GTFS download progress banner

    @ViewBuilder
    private var gtfsProgressBanner: some View {
        let progress = GTFSDownloadProgress.shared
        if progress.isActive {
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.stage)
                        .font(.transit(13, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    if !progress.detail.isEmpty {
                        Text(progress.detail)
                            .font(.transit(12, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                    }
                    Text("This only happens once.")
                        .font(.transit(12, weight: .medium))
                        .foregroundStyle(palette.textTertiary)
                        .italic()
                }
                Spacer()
            }
            .padding(12)
            .background(palette.mutedPanelBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.accentStrong.opacity(0.18), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Cards stack (always visible; redacted until data arrives)

    private var cardsStack: some View {
        VStack(spacing: 20) {
            if transportMode == .victorian {
                TrainCard(train: displayData.trainInfo)
            } else {
                BusCard(busInfo: displayData.busInfo ?? BusInfo.placeholder())
            }
            DrivingTimesCard(estimates: displayData.drivingEstimates, provider: drivingProvider)
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
                transportMode: transportMode,
                drivingProvider: drivingProvider,
                googleMapsApiKey: googleMapsApiKey,
                includeWeather: false
            )
            withAnimation(.spring(duration: 0.5)) {
                loadState = .loaded(data)
            }
            // Update scheduled notifications with live train data (avoids redundant fetch)
            if transportModeRaw == TransportMode.victorian.rawValue {
                await TrainNotificationManager.shared.scheduleWithTrainInfo(data.trainInfo)
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

// MARK: - Previews

#Preview("Idle — first launch") {
    ContentView()
        .environment(DrivingDestinationStore.shared)
        .environment(WeatherStationStore.shared)
}

#Preview("Loaded — real-looking data") {
    let weather = MockDataService.mockWeather()
    let events  = MockDataService.mockEvents()
    let train   = MockDataService.mockTrainInfo()
    let data    = DashboardData(weather: weather, upcomingEvents: events,
                                trainInfo: train,
                                busInfo: nil,
                                drivingEstimates: MockDataService.mockDrivingTimes(for: [
                                    DrivingDestination(name: "Office", address: "120 Spencer Street, Melbourne VIC 3000, Australia", latitude: -37.8175, longitude: 144.9520),
                                    DrivingDestination(name: "Airport", address: "Arrival Drive, Melbourne Airport VIC 3045, Australia", latitude: -37.6690, longitude: 144.8410)
                                ]),
                                fetchedAt: Date())
    _LoadedPreview(data: data)
}

private struct _LoadedPreview: View {
    let data: DashboardData
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    TrainCard(train: data.trainInfo)
                    DrivingTimesCard(estimates: data.drivingEstimates, provider: .apple)
                    CalendarCard(events: data.upcomingEvents)
                }
                .padding()
            }
            .navigationTitle("My Latest")
        }
    }
}
