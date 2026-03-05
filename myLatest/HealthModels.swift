//
//  HealthModels.swift
//  myLatest
//
//  Data models for the Health tab.
//  Designed to be forward-compatible with HealthKit (real integration = Step 5).
//

import Foundation

// MARK: - Sleep

/// One night's sleep record (covers the previous night for the given date).
struct SleepRecord: Identifiable {
    let id          = UUID()
    let date        : Date    // calendar date the sleeper woke up on
    let totalMinutes: Int     // total time asleep (all stages)
    let deepMinutes : Int     // deep / slow-wave sleep
    let remMinutes  : Int     // REM sleep
    let coreMinutes : Int     // core / light sleep

    // Convenience
    var hours  : Int    { totalMinutes / 60 }
    var minutes: Int    { totalMinutes % 60 }
    var totalHoursDecimal: Double { Double(totalMinutes) / 60.0 }

    /// e.g. "7h 22m"
    var durationLabel: String {
        hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// Short weekday label for the bar chart  e.g. "Mon"
    var weekdayLabel: String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// Traffic-light quality colour intent (used by the view layer)
    var qualityLevel: QualityLevel {
        switch totalHoursDecimal {
        case 7.5...:  return .good
        case 6.0...:  return .fair
        default:      return .poor
        }
    }

    enum QualityLevel { case good, fair, poor }
}

// MARK: - Heart Rate

/// A single heart-rate measurement.
struct HeartRateSample: Identifiable {
    let id  = UUID()
    let timestamp: Date
    let bpm      : Int
}

/// Aggregated stats for a collection of heart-rate samples.
struct HeartRateStats {
    let samples : [HeartRateSample]
    let min     : Int
    let max     : Int
    let average : Int
    let latest  : Int?

    init(samples: [HeartRateSample]) {
        self.samples = samples
        let bpms = samples.map(\.bpm)
        min     = bpms.min() ?? 0
        max     = bpms.max() ?? 0
        average = bpms.isEmpty ? 0 : bpms.reduce(0, +) / bpms.count
        latest  = samples.last?.bpm
    }
}

// MARK: - Top-level container

struct HealthData {
    /// Last 7 nights, oldest → newest.
    let sleepRecords   : [SleepRecord]
    /// Today's readings from 12:01 am to now.
    let heartRateStats : HeartRateStats
}
