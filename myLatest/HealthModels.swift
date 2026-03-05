//
//  HealthModels.swift
//  myLatest
//
//  Data models for the Health tab.
//

import Foundation

// MARK: - Sleep

/// One night's sleep record (covers the previous night for the given date).
struct SleepRecord: Identifiable {
    let id           = UUID()
    let date         : Date   // calendar date the sleeper woke up on
    let totalMinutes : Int    // total time asleep (all stages)
    let deepMinutes  : Int    // deep / slow-wave sleep
    let remMinutes   : Int    // REM sleep
    let coreMinutes  : Int    // core / light sleep

    var hours  : Int    { totalMinutes / 60 }
    var minutes: Int    { totalMinutes % 60 }
    var totalHoursDecimal: Double { Double(totalMinutes) / 60.0 }

    var durationLabel: String {
        hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var weekdayLabel: String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    var qualityLevel: QualityLevel {
        switch totalHoursDecimal {
        case 7.5...: return .good
        case 6.0...: return .fair
        default:     return .poor
        }
    }

    enum QualityLevel { case good, fair, poor }
}

// MARK: - Heart Rate

struct HeartRateSample: Identifiable {
    let id        = UUID()
    let timestamp : Date
    let bpm       : Int
}

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

// MARK: - Weekly Distance

/// One day's walking / running distance, carrying both the current and previous week's totals.
struct WeeklyDistanceDay: Identifiable {
    let id           = UUID()
    let weekdayIndex : Int    // 0 = Mon … 6 = Sun
    let weekdayLabel : String // "Mon", "Tue", …
    let thisWeekKm   : Double
    let lastWeekKm   : Double
}

/// A full week's daily distances plus running totals for this week and last week.
struct WeeklyDistanceData {
    /// Always 7 entries, Monday → Sunday.
    let days            : [WeeklyDistanceDay]
    let thisWeekTotalKm : Double
    let lastWeekTotalKm : Double
    /// Monday midnight (Melbourne time) that opened the current week.
    let weekStartDate   : Date
}

// MARK: - Activity

/// Broad workout categories shown on the Activity card.
enum ActivityCategory: String, CaseIterable, Identifiable {
    var id: String { rawValue }
    case walking  = "Walking"
    case core     = "Core"
    case strength = "Strength"
    case gym      = "Gym"
}

/// Weekly aggregated stats for one activity category (this week vs last week).
struct ActivityWeekSummary: Identifiable {
    let id               = UUID()
    let category         : ActivityCategory
    let thisWeekMinutes  : Int
    let thisWeekSessions : Int
    let lastWeekMinutes  : Int
    let lastWeekSessions : Int

    /// Returns e.g. "1h 30m", "45m", or "—" for zero.
    static func durationLabel(_ minutes: Int) -> String {
        guard minutes > 0 else { return "—" }
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }
}

/// Top-level container for all workout-related metrics.
struct WorkoutData {
    let weeklyDistance : WeeklyDistanceData
    let activities     : [ActivityWeekSummary]
}

// MARK: - Top-level container

struct HealthData {
    let sleepRecords   : [SleepRecord]
    let heartRateStats : HeartRateStats
    let workoutData    : WorkoutData
}
