//
//  TrainNotificationSettingsView.swift
//  myLatest
//
//  Settings view for configuring train status notifications.
//  Allows selecting days of the week and up to 5 notification times.
//

import SwiftUI

struct TrainNotificationSettingsView: View {
    @State private var manager = TrainNotificationManager.shared
    @State private var showingTimePicker = false
    @State private var newTime = Date()
    @State private var editingTimeIndex: Int?

    var body: some View {
        Form {
            // MARK: - Enable/Disable
            Section {
                Toggle("Enable Notifications", isOn: $manager.schedule.isEnabled)
                    .onChange(of: manager.schedule.isEnabled) { _, enabled in
                        if enabled {
                            Task { await manager.requestAuthorization() }
                        }
                    }
            } footer: {
                if manager.authorizationStatus == .denied {
                    Text("Notifications are disabled in System Settings. Please enable them for myLatest in Settings → Notifications.")
                        .foregroundStyle(.red)
                } else {
                    Text("When enabled, you'll receive train status updates at your scheduled times.")
                }
            }

            if manager.schedule.isEnabled {
                // MARK: - Days
                Section {
                    ForEach(TrainNotificationManager.dayNames, id: \.weekday) { day in
                        Toggle(day.full, isOn: dayBinding(for: day.weekday))
                    }
                } header: {
                    Text("Active Days")
                } footer: {
                    Text("Select which days you want to receive train status notifications.")
                }

                // Quick select buttons
                Section {
                    HStack {
                        Button("Weekdays") {
                            manager.schedule.enabledDays = [2, 3, 4, 5, 6]
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("Weekends") {
                            manager.schedule.enabledDays = [1, 7]
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("Every Day") {
                            manager.schedule.enabledDays = [1, 2, 3, 4, 5, 6, 7]
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Spacer()

                        Button("Clear") {
                            manager.schedule.enabledDays = []
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                        .tint(.red)
                    }
                }

                // MARK: - Times
                Section {
                    if manager.schedule.times.isEmpty {
                        Text("No notification times set")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(manager.schedule.times.enumerated()), id: \.element.id) { index, time in
                            HStack {
                                Image(systemName: "bell.fill")
                                    .foregroundStyle(.orange)
                                Text(time.displayString)
                                    .font(.body.monospacedDigit())
                                Spacer()
                                Button {
                                    editingTimeIndex = index
                                    newTime = time.asDate
                                    showingTimePicker = true
                                } label: {
                                    Image(systemName: "pencil.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .onDelete { indices in
                            manager.schedule.times.remove(atOffsets: indices)
                        }
                    }

                    if manager.schedule.times.count < NotificationSchedule.maxTimes {
                        Button {
                            editingTimeIndex = nil
                            newTime = defaultNewTime()
                            showingTimePicker = true
                        } label: {
                            Label("Add Notification Time", systemImage: "plus.circle.fill")
                        }
                    }
                } header: {
                    Text("Notification Times (\(manager.schedule.times.count)/\(NotificationSchedule.maxTimes))")
                } footer: {
                    Text("Set up to \(NotificationSchedule.maxTimes) notification times per day. Swipe left to delete a time.")
                }

                // MARK: - Summary
                if !manager.schedule.enabledDays.isEmpty && !manager.schedule.times.isEmpty {
                    Section {
                        summaryView
                    } header: {
                        Text("Schedule Summary")
                    }
                }
            }
        }
        .navigationTitle("Train Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingTimePicker) {
            timePickerSheet
        }
        .task {
            await manager.checkAuthorizationStatus()
        }
    }

    // MARK: - Time Picker Sheet

    private var timePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(editingTimeIndex != nil ? "Edit Notification Time" : "Add Notification Time")
                    .font(.headline)

                DatePicker("Time", selection: $newTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()

                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingTimePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingTimeIndex != nil ? "Update" : "Add") {
                        let entry = NotificationTimeEntry.from(date: newTime)
                        if let index = editingTimeIndex {
                            manager.schedule.times[index] = entry
                        } else {
                            manager.schedule.times.append(entry)
                        }
                        // Sort times chronologically
                        manager.schedule.times.sort { ($0.hour * 60 + $0.minute) < ($1.hour * 60 + $1.minute) }
                        showingTimePicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Summary

    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 8) {
            let sortedDays = manager.schedule.enabledDays.sorted()
            let dayLabels = sortedDays.compactMap { weekday in
                TrainNotificationManager.dayNames.first(where: { $0.weekday == weekday })?.short
            }

            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(.blue)
                Text(dayLabels.joined(separator: ", "))
                    .font(.subheadline)
            }

            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.orange)
                Text(manager.schedule.times.map(\.displayString).joined(separator: ", "))
                    .font(.subheadline)
            }

            let totalPerWeek = manager.schedule.enabledDays.count * manager.schedule.times.count
            Text("\(totalPerWeek) notifications per week")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func dayBinding(for weekday: Int) -> Binding<Bool> {
        Binding(
            get: { manager.schedule.enabledDays.contains(weekday) },
            set: { enabled in
                if enabled {
                    manager.schedule.enabledDays.insert(weekday)
                } else {
                    manager.schedule.enabledDays.remove(weekday)
                }
            }
        )
    }

    private func defaultNewTime() -> Date {
        var components = DateComponents()
        components.hour = 7
        components.minute = 30
        return Calendar.current.date(from: components) ?? .now
    }
}
