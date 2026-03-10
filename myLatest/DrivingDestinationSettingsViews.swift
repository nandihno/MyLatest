//
//  DrivingDestinationSettingsViews.swift
//  myLatest
//

import Combine
import Foundation
import MapKit
import SwiftUI

struct DrivingDestinationsView: View {
    @Environment(DrivingDestinationStore.self) private var store
    @State private var showAdd = false

    var body: some View {
        List {
            Section {
                if store.custom.isEmpty {
                    Text("No destinations yet — tap + to add one.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(store.custom) { destination in
                        DrivingDestinationRow(destination: destination)
                    }
                    .onDelete { store.delete(offsets: $0) }
                }
            } header: {
                Text("Saved Destinations (\(store.custom.count))")
            } footer: {
                Text("These destinations are used on the Commuting tab to calculate current driving times from your device location. Swipe left to delete one.")
            }
        }
        .navigationTitle("Driving Destinations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddDrivingDestinationView()
        }
    }
}

private struct DrivingDestinationRow: View {
    let destination: DrivingDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(destination.name)
                .font(.body)

            Text(destination.address)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

struct AddDrivingDestinationView: View {
    @Environment(DrivingDestinationStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var searchModel = DestinationSearchModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Start typing an address", text: $searchModel.query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    if searchModel.isSearching {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching Apple Maps…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage = searchModel.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Destination Search")
                } footer: {
                    Text("Choose a suggestion to lock in the exact destination the app should route to.")
                }

                if let selectedDestination = searchModel.selectedDestination {
                    Section {
                        DrivingDestinationRow(destination: selectedDestination)
                    } header: {
                        Text("Selected Destination")
                    }
                }

                Section {
                    if searchModel.suggestions.isEmpty {
                        Text(searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 3
                             ? "Enter at least 3 characters to see suggestions."
                             : "No matching addresses found yet.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(searchModel.suggestions) { suggestion in
                            Button {
                                searchModel.select(suggestion)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(suggestion.title)
                                        .foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Suggestions")
                }
            }
            .navigationTitle("Add Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(searchModel.selectedDestination == nil)
                }
            }
        }
    }

    private func save() {
        guard let destination = searchModel.selectedDestination else { return }
        store.add(destination)
        dismiss()
    }
}

@MainActor
final class DestinationSearchModel: NSObject, ObservableObject {
    struct Suggestion: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        fileprivate let completion: MKLocalSearchCompletion
    }

    @Published var query = "" {
        didSet { handleQueryChange() }
    }
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var selectedDestination: DrivingDestination?
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    private let completer = MKLocalSearchCompleter()
    private var suppressQuerySideEffects = false

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func select(_ suggestion: Suggestion) {
        Task {
            await resolve(suggestion)
        }
    }

    private func handleQueryChange() {
        guard !suppressQuerySideEffects else { return }

        selectedDestination = nil
        errorMessage = nil

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            suggestions = []
            isSearching = false
            completer.queryFragment = ""
            return
        }

        isSearching = true
        completer.queryFragment = trimmed
    }

    private func resolve(_ suggestion: Suggestion) async {
        isSearching = true
        errorMessage = nil

        do {
            let request = MKLocalSearch.Request(completion: suggestion.completion)
            request.resultTypes = .address

            let response = try await Self.startSearch(request)
            guard
                let item = response.mapItems.first,
                let location = item.placemark.location
            else {
                errorMessage = "The selected address could not be resolved."
                isSearching = false
                return
            }

            let resolved = DrivingDestination(
                name: item.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? suggestion.title,
                address: Self.formattedAddress(for: item.placemark, fallbackSubtitle: suggestion.subtitle),
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )

            suppressQuerySideEffects = true
            query = resolved.address
            suppressQuerySideEffects = false

            selectedDestination = resolved
            suggestions = []
            isSearching = false
        } catch is CancellationError {
            errorMessage = "Address search was cancelled."
            isSearching = false
        } catch {
            errorMessage = error.localizedDescription
            isSearching = false
        }
    }

    private static func startSearch(_ request: MKLocalSearch.Request) async throws -> MKLocalSearch.Response {
        let search = MKLocalSearch(request: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                search.start { response, error in
                    if let response {
                        continuation.resume(returning: response)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: LocationError.unavailable)
                    }
                }
            }
        } onCancel: {
            search.cancel()
        }
    }

    private static func formattedAddress(for placemark: MKPlacemark, fallbackSubtitle: String) -> String {
        let components = [
            placemark.subThoroughfare,
            placemark.thoroughfare,
            placemark.locality,
            placemark.administrativeArea,
            placemark.postalCode,
            placemark.country
        ]
        .compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        if !components.isEmpty {
            return components.joined(separator: ", ")
        }

        if let title = placemark.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return title
        }

        return fallbackSubtitle.isEmpty ? "Selected destination" : fallbackSubtitle
    }
}

extension DestinationSearchModel: MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results.map {
            Suggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
        }
        isSearching = false
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
        errorMessage = error.localizedDescription
        isSearching = false
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
