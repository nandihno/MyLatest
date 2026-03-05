//
//  ContentView.swift
//  myLatest
//

import SwiftUI

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
            WeatherCard(weather: displayData.weather)
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
        // On the very first fetch (idle state) show the skeleton/placeholder cards
        // so the layout doesn't jump. On subsequent refreshes (data already on screen)
        // keep the existing data visible and silently swap in the new data when it
        // arrives — the pull-to-refresh spinner provides all the visual feedback needed.
        if !loadState.isLoaded {
            withAnimation { loadState = .loading }
        }
        let data = await MockDataService.shared.fetchDashboard(
            trainLineName: trainLineName,
            homeStation:   homeStation,
            cityStation:   cityStation
        )
        withAnimation(.spring(duration: 0.5)) {
            loadState = .loaded(data)
        }
    }
}

// MARK: - Weather Card

struct WeatherCard: View {
    let weather: WeatherInfo

    private var latest: WeatherObservation? { weather.observations.first }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {

                Label("Weather", systemImage: "cloud.sun.fill")
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

                        HStack(spacing: 10) {
                            Text(latest?.cloud ?? "--")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let hum = latest?.relHumidity {
                                HStack(spacing: 3) {
                                    Image(systemName: "drop.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                    Text("\(hum)%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Spacer()

                    Image(systemName: latest?.symbolName ?? "sun.max.fill")
                        .font(.system(size: 52))
                        .symbolRenderingMode(.multicolor)
                }

                Divider()

                // ── Observation history table ────────────────────────────
                observationTable
            }
        }
    }

    private var observationTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text("Time")      .gridColumnAlignment(.leading)
                Text("Feels")     .gridColumnAlignment(.trailing)
                Text("Humidity")  .gridColumnAlignment(.trailing)
                Text("Condition") .gridColumnAlignment(.leading)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)

            ForEach(weather.observations) { obs in
                GridRow {
                    Text(obs.localDateTime)
                    Text(String(format: "%.1f°", obs.apparentTemp))
                    Text("\(obs.relHumidity)%")
                    Text(obs.cloud).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
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
                    WeatherCard(weather: data.weather)
                    CalendarCard(events: data.upcomingEvents)
                    TrainCard(train: data.trainInfo)
                }
                .padding()
            }
            .navigationTitle("My Latest")
        }
    }
}
