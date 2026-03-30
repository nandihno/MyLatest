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
    @AppStorage("transportMode") private var transportModeRaw: String = TransportMode.victorian.rawValue

    @Environment(\.dismiss) private var dismiss
    @Environment(WeatherStationStore.self) private var stationStore
    @Environment(DrivingDestinationStore.self) private var drivingDestinationStore
    @AppStorage("claudeApiKey") private var claudeApiKey: String = ""
    @AppStorage("googleMapsApiKey") private var googleMapsApiKey: String = ""
    @AppStorage("drivingProvider") private var drivingProviderRaw: String = DrivingProvider.apple.rawValue
    @AppStorage("aiProvider") private var aiProviderRaw: String = AIProvider.appleIntelligence.rawValue
    @AppStorage("userAge")      private var userAge:      String = ""
    @State private var showDeleteGTFSConfirmation = false
    @State private var gtfsRedownloadStatus = ""
    @State private var gtfsDataReady = false
    @State private var gtfsDownloadInProgress = false

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

    var body: some View {
        NavigationStack {
            Form {
                // ── Transport Mode ─────────────────────────────────────
                Section {
                    Picker("Region", selection: $transportModeRaw) {
                        Text("Victorian Transport").tag(TransportMode.victorian.rawValue)
                        Text("Queensland Transport").tag(TransportMode.queensland.rawValue)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Transport Region")
                } footer: {
                    if transportModeRaw == TransportMode.victorian.rawValue {
                        Text("Showing Metro Trains Melbourne in the Commuting section.")
                    } else {
                        Text("Showing SEQ bus departures near your location in the Commuting section.")
                    }
                }

                // ── Train (Victorian only) ─────────────────────────────
                if transportModeRaw == TransportMode.victorian.rawValue {
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
                        Text("Train")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("**Line** — tap to choose from all Metro Trains Melbourne lines.", systemImage: "tram.fill")
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

                // ── Train Notifications (Victorian only) ──────────────
                if transportModeRaw == TransportMode.victorian.rawValue {
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
                        Text("Notifications")
                    } footer: {
                        Text("Schedule notifications to receive train status updates at specific days and times.")
                    }
                }

                // ── Queensland Bus Info ────────────────────────────────
                if transportModeRaw == TransportMode.queensland.rawValue {
                    Section {
                        if gtfsDataReady {
                            NavigationLink {
                                FavouriteBusStopsView()
                            } label: {
                                HStack {
                                    Text("Favourite Stops")
                                    Spacer()
                                    Text("\(FavouriteBusStopStore.shared.all.count)")
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

                    if gtfsDataReady {
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
                            Text("Bus Data Management")
                        }
                    }
                }

                // ── Driving ──────────────────────────────────────────────
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
                    Text("Driving")
                } footer: {
                    if useGoogleMaps.wrappedValue {
                        Text("Using Google Routes API for driving times. Get an API key at console.cloud.google.com.")
                    } else {
                        Text("Using Apple Maps for driving times. Toggle on to use Google Maps instead.")
                    }
                }

                // ── Profile ──────────────────────────────────────────────
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
                    Text("Profile")
                } footer: {
                    Text("Used to personalise your AI health analysis, along with the current date and time.")
                }

                // ── AI Provider ──────────────────────────────────────────
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
                    Text("AI Provider")
                } footer: {
                    if useClaude.wrappedValue {
                        Text("Using Claude AI for health and weather analysis. Get an API key at console.anthropic.com.")
                    } else {
                        Text("Using Apple Intelligence (on-device) for health and weather analysis. Toggle on to use Claude AI instead.")
                    }
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

                // ── Version ─────────────────────────────────────────────
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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                gtfsDataReady = await GTFSDatabase.shared.isDatabaseReady()
            }
        }
    }
}
