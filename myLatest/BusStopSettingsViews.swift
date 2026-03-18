//
//  BusStopSettingsViews.swift
//  myLatest
//
//  Settings views for searching and managing favourite bus stops.
//  Searches the local GTFS SQLite database for bus stops by name.
//

import SwiftUI
import SQLite3

// MARK: - Favourite Bus Stops List

struct FavouriteBusStopsView: View {
    @Environment(FavouriteBusStopStore.self) private var store

    var body: some View {
        List {
            if store.all.isEmpty {
                ContentUnavailableView {
                    Label("No Favourite Stops", systemImage: "star.slash")
                } description: {
                    Text("Tap the + button to search and add bus stops.")
                }
            } else {
                ForEach(store.all) { stop in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.stopName)
                            .font(.body)
                        if let code = stop.stopCode {
                            Text("Stop #\(code)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    store.delete(offsets: offsets)
                }
            }
        }
        .navigationTitle("Favourite Stops")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    BusStopSearchView()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

// MARK: - Bus Stop Search

struct BusStopSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FavouriteBusStopStore.self) private var store

    @State private var searchText = ""
    @State private var results: [BusStopSearchResult] = []
    @State private var isSearching = false
    @State private var dbReady = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if !dbReady {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Loading bus stop database…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if results.isEmpty && !searchText.isEmpty && !isSearching {
                ContentUnavailableView.search(text: searchText)
            } else {
                ForEach(results) { stop in
                    Button {
                        addStop(stop)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stop.stopName)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                if let code = stop.stopCode {
                                    Text("Stop #\(code)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if store.contains(stopId: stop.stopId) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(store.contains(stopId: stop.stopId))
                }
            }
        }
        .navigationTitle("Search Bus Stops")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search by stop name")
        .onChange(of: searchText) {
            performSearch()
        }
        .task {
            await checkDatabase()
        }
    }

    private func checkDatabase() async {
        do {
            try await GTFSDatabase.shared.ensureReady()
            dbReady = true
        } catch {
            errorMessage = "Bus stop database not available. Fetch bus data first from the Commuting tab."
        }
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, dbReady else {
            results = []
            return
        }

        isSearching = true
        Task {
            do {
                let found = try await GTFSDatabase.shared.searchBusStops(name: query, limit: 30)
                results = found
            } catch {
                results = []
            }
            isSearching = false
        }
    }

    private func addStop(_ stop: BusStopSearchResult) {
        store.add(FavouriteBusStop(
            stopId: stop.stopId,
            stopName: stop.stopName,
            stopCode: stop.stopCode,
            latitude: stop.latitude,
            longitude: stop.longitude
        ))
    }
}

// MARK: - Search result model

struct BusStopSearchResult: Identifiable {
    let stopId: String
    let stopName: String
    let stopCode: String?
    let latitude: Double
    let longitude: Double

    var id: String { stopId }
}
