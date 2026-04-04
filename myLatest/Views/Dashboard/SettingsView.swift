//
//  SettingsView.swift
//  myLatest
//

import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Binding var trainLineName: String
    @AppStorage("homeStation") private var homeStation: String = ""
    @AppStorage("cityStation") private var cityStation: String = "Flinders Street"
    @AppStorage("transportMode") private var transportRegionRaw: String = TransportRegion.victorian.rawValue
    @AppStorage("victorianShowTrainCard") private var victorianShowTrainCard = true
    @AppStorage("victorianShowBusCard") private var victorianShowBusCard = false
    @AppStorage(VictorianBusService.realtimeAPIKeyDefaultsKey) private var victorianGTFSRealtimeApiKey: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(WeatherStationStore.self) private var stationStore
    @Environment(DrivingDestinationStore.self) private var drivingDestinationStore
    @AppStorage("claudeApiKey") private var claudeApiKey: String = ""
    @AppStorage("googleMapsApiKey") private var googleMapsApiKey: String = ""
    @AppStorage("drivingProvider") private var drivingProviderRaw: String = DrivingProvider.apple.rawValue
    @AppStorage("aiProvider") private var aiProviderRaw: String = AIProvider.appleIntelligence.rawValue
    @AppStorage("userAge")      private var userAge:      String = ""
    @State private var showDeleteGTFSConfirmation = false
    @State private var showDeleteVictorianGTFSConfirmation = false
    @State private var gtfsRedownloadStatus = ""
    @State private var gtfsDataReady = false
    @State private var gtfsDownloadInProgress = false
    @State private var victorianBundledDBAvailable = false

    private var useGoogleMaps: Binding<Bool> {
        Binding(
            get: { drivingProviderRaw == DrivingProvider.google.rawValue },
            set: { drivingProviderRaw = ($0 ? DrivingProvider.google : DrivingProvider.apple).rawValue }
        )
    }
    private var useClaude: Binding<Bool> {
        Binding(
            get: { aiProviderRaw == AIProvider.claude.rawValue },
            set: { aiProviderRaw = ($0 ? AIProvider.claude : AIProvider.appleIntelligence).rawValue }
        )
    }
    @AppStorage("userExtraInformation") private var userExtraInformation: String = ""

    private var transportRegion: TransportRegion {
        TransportRegion(rawValue: transportRegionRaw) ?? .victorian
    }

    var body: some View {
        NavigationStack {
            Form {
                dashboardSection

                if transportRegion == .victorian && victorianShowTrainCard {
                    victorianTrainSection
                    trainNotificationsSection
                }

                transportBusSections

                placesSection
                integrationsSection
                profileSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await refreshGTFSState()
            }
            .onChange(of: transportRegionRaw) { _, _ in
                Task { await refreshGTFSState() }
            }
            .onChange(of: victorianShowBusCard) { _, _ in
                Task { await refreshGTFSState() }
            }
        }
    }

    @ViewBuilder
    private var dashboardSection: some View {
        Section {
            Picker("Region", selection: $transportRegionRaw) {
                Text("Victorian Transport").tag(TransportRegion.victorian.rawValue)
                Text("Queensland Transport").tag(TransportRegion.queensland.rawValue)
            }
            .pickerStyle(.segmented)

            if transportRegion == .victorian {
                Toggle("Show Train Card", isOn: $victorianShowTrainCard)
                Toggle("Show Bus Card", isOn: $victorianShowBusCard)
            }
        } header: {
            Text("Commuting Dashboard")
        } footer: {
            if transportRegion == .victorian {
                if victorianShowBusCard {
                    Text("Choose which Victorian commuting cards appear on the dashboard. The bus card uses the local GTFS database and can overlay live PTV GTFS-RT predictions when a realtime API key is configured.")
                } else {
                    Text("Choose which Victorian commuting cards appear on the dashboard.")
                }
            } else {
                Text("SEQ bus departures are shown near your location in the Commuting section.")
            }
        }
    }

    @ViewBuilder
    private var victorianTrainSection: some View {
        Section {
            NavigationLink {
                TrainLinePickerView(selectedLineName: $trainLineName)
            } label: {
                LabeledContent("Line") {
                    Text(trainLineName.isEmpty ? "Not set" : trainLineName)
                        .foregroundStyle(trainLineName.isEmpty ? .secondary : .primary)
                }
            }

            NavigationLink {
                StationPickerView(title: "Home Station", selectedStation: $homeStation)
            } label: {
                LabeledContent("Home Station") {
                    Text(homeStation.isEmpty ? "Not set" : homeStation)
                        .foregroundStyle(homeStation.isEmpty ? .secondary : .primary)
                }
            }
            .disabled(trainLineName.isEmpty)

            NavigationLink {
                StationPickerView(title: "City Station", selectedStation: $cityStation)
            } label: {
                LabeledContent("City Station") {
                    Text(cityStation.isEmpty ? "Not set" : cityStation)
                        .foregroundStyle(cityStation.isEmpty ? .secondary : .primary)
                }
            }
            .disabled(trainLineName.isEmpty)
        } header: {
            Text("Victorian Train")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Label("**Line** — choose from all Metro Trains Melbourne lines.", systemImage: "tram.fill")
                Label("**Home Station** — your local station for departures.", systemImage: "house.fill")
                Label("**City Station** — your city station for return departures.", systemImage: "building.2.fill")
                if trainLineName.isEmpty {
                    Text("Select a train line first to enable station selection.")
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private var trainNotificationsSection: some View {
        Section {
            NavigationLink {
                TrainNotificationSettingsView()
            } label: {
                HStack {
                    Label("Train Notifications", systemImage: "bell.badge.fill")
                    Spacer()
                    if TrainNotificationManager.shared.schedule.isEnabled {
                        Text("\(TrainNotificationManager.shared.schedule.times.count) times")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Off")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Train Notifications")
        } footer: {
            Text("Schedule notifications to receive train status updates at specific days and times.")
        }
    }

    @ViewBuilder
    private var transportBusSections: some View {
        if transportRegion == .queensland {
            queenslandBusSetupSection
            if gtfsDataReady {
                queenslandBusDataManagementSection
            }
        }

        if transportRegion == .victorian && victorianShowBusCard {
            victorianBusSetupSection
            if gtfsDataReady {
                victorianBusDataManagementSection
            }
        }
    }

    @ViewBuilder
    private var queenslandBusSetupSection: some View {
        Section {
            if gtfsDataReady {
                NavigationLink {
                    FavouriteBusStopsView()
                } label: {
                    HStack {
                        Text("Favourite Stops")
                        Spacer()
                        Text("\(FavouriteBusStopStore.shared.count(for: .queenslandTransLink))")
                            .foregroundStyle(.secondary)
                    }
                }
                Label("Nearby stops within 300m are also shown automatically.", systemImage: "location.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if gtfsDownloadInProgress {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading) {
                        Text(GTFSDownloadProgress.shared.stage.isEmpty ? "Downloading bus data…" : GTFSDownloadProgress.shared.stage)
                            .font(.subheadline)
                        if !GTFSDownloadProgress.shared.detail.isEmpty {
                            Text(GTFSDownloadProgress.shared.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Bus schedule data needs to be downloaded before you can search and add favourite stops.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)

                    Button {
                        gtfsDownloadInProgress = true
                        Task {
                            do {
                                try await GTFSDatabase.shared.ensureReady()
                                gtfsDataReady = true
                            } catch {
                                gtfsRedownloadStatus = "Download failed: \(error.localizedDescription)"
                            }
                            gtfsDownloadInProgress = false
                        }
                    } label: {
                        Label("Download Bus Data (~26 MB)", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text("SEQ Bus")
        } footer: {
            Text("Data provided by TransLink. Schedule and real-time data is downloaded on first use (~26 MB). Times are displayed in Queensland time (AEST, UTC+10).")
        }
    }

    @ViewBuilder
    private var queenslandBusDataManagementSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteGTFSConfirmation = true
            } label: {
                Label("Delete & Re-download Bus Data", systemImage: "arrow.triangle.2.circlepath")
            }
            .confirmationDialog(
                "Delete Bus Data?",
                isPresented: $showDeleteGTFSConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete & Re-download", role: .destructive) {
                    Task {
                        do {
                            try await GTFSDatabase.shared.resetDatabase()
                            gtfsDataReady = false
                            gtfsRedownloadStatus = ""
                        } catch {
                            gtfsRedownloadStatus = "Error: \(error.localizedDescription)"
                        }
                    }
                }
            } message: {
                Text("This will delete the cached bus schedule data (~26 MB). You will need to re-download it to use favourite stops and bus departures.")
            }

            if !gtfsRedownloadStatus.isEmpty {
                Text(gtfsRedownloadStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("SEQ Bus Data")
        }
    }

    @ViewBuilder
    private var victorianBusSetupSection: some View {
        Section {
            LabeledContent("Realtime API Key") {
                TextField("Ocp-Apim key", text: $victorianGTFSRealtimeApiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
            }

            if victorianGTFSRealtimeApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("Scheduled departures still work without this key. Add it to unlock live late/early predictions.", systemImage: "clock.badge.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if gtfsDataReady {
                NavigationLink {
                    FavouriteBusStopsView(provider: .victorianPTV)
                } label: {
                    HStack {
                        Text("Favourite Stops")
                        Spacer()
                        Text("\(FavouriteBusStopStore.shared.count(for: .victorianPTV))")
                            .foregroundStyle(.secondary)
                    }
                }
                Label("Nearby Melbourne bus stops are available once the PTV GTFS dataset has been installed.", systemImage: "location.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if gtfsDownloadInProgress {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading) {
                        Text(GTFSDownloadProgress.shared.stage.isEmpty ? "Downloading Victorian bus data…" : GTFSDownloadProgress.shared.stage)
                            .font(.subheadline)
                        if !GTFSDownloadProgress.shared.detail.isEmpty {
                            Text(GTFSDownloadProgress.shared.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Download the Victorian GTFS dataset before browsing and saving Melbourne bus stops.", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        gtfsRedownloadStatus = ""
                        gtfsDownloadInProgress = true
                        Task {
                            do {
                                try await VictorianBusGTFSDatabase.shared.ensureReady()
                                gtfsDataReady = true
                            } catch {
                                print("Victorian GTFS download failed:", error.localizedDescription)
                                gtfsRedownloadStatus = "Download failed: \(error.localizedDescription)"
                            }
                            gtfsDownloadInProgress = false
                        }
                    } label: {
                        Label("Download Victorian Bus Data (~213 MB)", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if !gtfsRedownloadStatus.isEmpty {
                        Text(gtfsRedownloadStatus)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showDeleteVictorianGTFSConfirmation = true
                    } label: {
                        Label(victorianBundledDBAvailable ? "Reset Installed Victorian Bus Data" : "Reset Victorian Bus Setup", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .confirmationDialog(
                        "Reset Victorian Bus Setup?",
                        isPresented: $showDeleteVictorianGTFSConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Reset Setup", role: .destructive) {
                            Task {
                                do {
                                    try await VictorianBusGTFSDatabase.shared.resetDatabase()
                                    gtfsDataReady = false
                                    gtfsDownloadInProgress = false
                                    gtfsRedownloadStatus = victorianBundledDBAvailable
                                        ? "Victorian bus data was cleared. The bundled database will be restored automatically on next use."
                                        : "Victorian bus data was cleared. You can start the download again."
                                } catch {
                                    gtfsRedownloadStatus = "Reset failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    } message: {
                        Text(victorianBundledDBAvailable
                             ? "This clears the installed Victorian bus database in the app cache. The bundled database shipped with the app will be restored automatically on next use."
                             : "This clears any downloaded Victorian GTFS ZIP, partial extraction files, and the local bus database so you can start the setup again from scratch.")
                    }
                }
            }
        } header: {
            Text("Victorian Bus")
        } footer: {
            Text(victorianBundledDBAvailable
                 ? "Static stop and timetable data is bundled with the app and installed locally on first use. Live departure predictions come from the Transport Victoria GTFS-RT metro-bus trip updates feed when a realtime key is configured."
                 : "Static stop and timetable data comes from the Transport Victoria GTFS Schedule download. Live departure predictions come from the Transport Victoria GTFS-RT metro-bus trip updates feed when a realtime key is configured.")
        }
    }

    @ViewBuilder
    private var victorianBusDataManagementSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteVictorianGTFSConfirmation = true
            } label: {
                Label(victorianBundledDBAvailable ? "Reinstall Bundled Victorian Bus Data" : "Delete & Re-download Victorian Bus Data", systemImage: "arrow.triangle.2.circlepath")
            }
            .confirmationDialog(
                "Delete Victorian Bus Data?",
                isPresented: $showDeleteVictorianGTFSConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete & Re-download", role: .destructive) {
                    Task {
                        do {
                            try await VictorianBusGTFSDatabase.shared.resetDatabase()
                            gtfsDataReady = false
                            gtfsDownloadInProgress = false
                            gtfsRedownloadStatus = victorianBundledDBAvailable
                                ? "Victorian bus data was cleared. The bundled database will be restored automatically on next use."
                                : "Victorian bus data was cleared. Start the download again when ready."
                        } catch {
                            gtfsRedownloadStatus = "Error: \(error.localizedDescription)"
                        }
                    }
                }
            } message: {
                Text(victorianBundledDBAvailable
                     ? "This removes the installed Victorian bus timetable database from cache. The bundled database will be restored automatically the next time the app needs it."
                     : "This removes the cached Victorian bus timetable database. You will need to download it again before managing favourite Melbourne bus stops.")
            }

            if !gtfsRedownloadStatus.isEmpty {
                Text(gtfsRedownloadStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Victorian Bus Data")
        }
    }

    @ViewBuilder
    private var placesSection: some View {
        Section {
            NavigationLink {
                DrivingDestinationsView()
            } label: {
                HStack {
                    Text("Driving Destinations")
                    Spacer()
                    Text("\(drivingDestinationStore.all.count)")
                        .foregroundStyle(.secondary)
                }
            }

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
            Text("Saved Places")
        } footer: {
            Text("Manage destination shortcuts for driving times and custom BOM weather stations.")
        }
    }

    @ViewBuilder
    private var integrationsSection: some View {
        Section {
            Toggle("Use Google Maps", isOn: useGoogleMaps)
            if useGoogleMaps.wrappedValue {
                LabeledContent("API Key") {
                    TextField("AIza...", text: $googleMapsApiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("Driving Provider")
        } footer: {
            if useGoogleMaps.wrappedValue {
                Text("Using Google Routes API for driving times. Get an API key at console.cloud.google.com.")
            } else {
                Text("Using Apple Maps for driving times. Toggle on to use Google Maps instead.")
            }
        }

        Section {
            Toggle("Use Claude AI", isOn: useClaude)
            if useClaude.wrappedValue {
                LabeledContent("API Key") {
                    TextField("sk-ant-...", text: $claudeApiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("AI Analysis")
        } footer: {
            if useClaude.wrappedValue {
                Text("Using Claude AI for health and weather analysis. Get an API key at console.anthropic.com.")
            } else {
                Text("Using Apple Intelligence (on-device) for health and weather analysis. Toggle on to use Claude AI instead.")
            }
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        Section {
            LabeledContent("Age") {
                TextField("e.g. 35", text: $userAge)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Extra Information")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Anything Claude should consider about your health or lifestyle", text: $userExtraInformation, axis: .vertical)
                    .lineLimit(3...5)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Personalisation")
        } footer: {
            Text("Used to personalise your AI health analysis, along with the current date and time.")
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
        } footer: {
            HStack {
                Spacer()
                Text("MyLatest v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    @MainActor
    private func refreshGTFSState() async {
        guard transportRegion == .queensland || (transportRegion == .victorian && victorianShowBusCard) else {
            gtfsDataReady = false
            gtfsDownloadInProgress = false
            gtfsRedownloadStatus = ""
            victorianBundledDBAvailable = false
            return
        }

        switch transportRegion {
        case .queensland:
            victorianBundledDBAvailable = false
            gtfsDataReady = await GTFSDatabase.shared.isDatabaseReady()
        case .victorian:
            victorianBundledDBAvailable = await VictorianBusGTFSDatabase.shared.hasBundledDatabaseAsset()
            gtfsDataReady = await VictorianBusGTFSDatabase.shared.isDatabaseReady()
        }
    }
}
