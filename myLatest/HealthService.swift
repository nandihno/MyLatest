//
//  HealthService.swift
//  myLatest
//
//  Fetches real HealthKit data (sleep + heart rate) with a mock fallback when
//  HealthKit is unavailable (e.g. simulator) or the user hasn't granted access.
//

import Foundation
import HealthKit

@MainActor
final class HealthService {
    static let shared = HealthService()
    private init() {}

    private let store = HKHealthStore()

    private var sleepType: HKCategoryType {
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    }
    private var heartRateType: HKQuantityType {
        HKQuantityType(.heartRate)
    }

    // MARK: - Public API

    func fetchHealthData() async -> HealthData {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("⚕️ HealthKit not available — using mock data")
            return makeMockData()
        }

        do {
            try await store.requestAuthorization(toShare: [], read: [sleepType, heartRateType])
        } catch {
            print("⚕️ HealthKit auth error: \(error) — using mock data")
            return makeMockData()
        }

        // Fetch both concurrently.
        async let sleepTask = fetchSleepRecords()
        async let hrTask    = fetchHeartRateSamples()
        let (sleepRecs, hrSamples) = await (sleepTask, hrTask)

        // Fall back to mock for whichever dataset returned empty
        // (can happen if user denied only one permission).
        let finalSleep = sleepRecs.isEmpty   ? makeSleepRecords()    : sleepRecs
        let finalHR    = hrSamples.isEmpty   ? makeHeartRateSamples(): hrSamples

        return HealthData(
            sleepRecords:   finalSleep,
            heartRateStats: HeartRateStats(samples: finalHR)
        )
    }

    // MARK: - Sleep

    private func fetchSleepRecords() async -> [SleepRecord] {
        // Query the last 8 days so we can always surface 7 complete nights.
        var melbCal = Calendar.current
        melbCal.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let now       = Date()
        let startDate = melbCal.date(byAdding: .day, value: -8,
                                     to: melbCal.startOfDay(for: now))!

        let predicate     = HKQuery.predicateForSamples(withStart: startDate,
                                                        end: now,
                                                        options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                              ascending: true)

        let rawSamples: [HKCategorySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: sleepType,
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sortDescriptor]) { _, results, error in
                if let error { print("⚕️ Sleep query error: \(error)") }
                cont.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }

        return aggregateSleepByNight(rawSamples, calendar: melbCal)
    }

    private func aggregateSleepByNight(_ samples: [HKCategorySample],
                                       calendar melbCal: Calendar) -> [SleepRecord] {
        // We only count genuine sleep stages (not inBed).
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        let sleepSamples = samples.filter { asleepValues.contains($0.value) }

        // Assign each sample to a "wake date": the calendar date of its end
        // time in Melbourne, as long as it ends before 2pm (otherwise +1 day).
        var byWakeDate: [Date: [HKCategorySample]] = [:]
        for sample in sleepSamples {
            let hour     = melbCal.component(.hour, from: sample.endDate)
            let baseDate = melbCal.startOfDay(for: sample.endDate)
            let wakeDate = hour < 14
                ? baseDate
                : melbCal.date(byAdding: .day, value: 1, to: baseDate)!
            byWakeDate[wakeDate, default: []].append(sample)
        }

        // Return the most recent 7 nights, oldest → newest.
        return byWakeDate.keys.sorted().suffix(7).map { wakeDate in
            var nightSamples = byWakeDate[wakeDate]!

            // If Apple Watch / a detailed source recorded Core/Deep/REM stages,
            // drop any asleepUnspecified records to avoid double-counting.
            // (iPhone and third-party apps often write asleepUnspecified on top
            //  of the same intervals the Watch already broke into stages.)
            let hasDetailedStages = nightSamples.contains {
                $0.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue ||
                $0.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue ||
                $0.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
            }
            if hasDetailedStages {
                nightSamples = nightSamples.filter {
                    $0.value != HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                }
            }

            // Compute per-stage minutes by merging overlapping intervals first
            // (multiple sources can write overlapping records for the same stage).
            let deepMins = mergedMinutes(nightSamples.filter {
                $0.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
            })
            let remMins  = mergedMinutes(nightSamples.filter {
                $0.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
            })
            let coreMins = mergedMinutes(nightSamples.filter {
                $0.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue ||
                $0.value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
            })

            // Total = merge ALL stage intervals together so cross-stage overlaps
            // (e.g. an asleepCore record that overlaps an asleepDeep record from
            //  a different source) are not double-counted either.
            let totalMins = mergedMinutes(nightSamples)

            return SleepRecord(date: wakeDate,
                               totalMinutes: totalMins,
                               deepMinutes:  deepMins,
                               remMinutes:   remMins,
                               coreMinutes:  coreMins)
        }
    }

    /// Sorts samples by start date, merges any overlapping or adjacent intervals,
    /// and returns the total covered duration in whole minutes.
    private func mergedMinutes(_ samples: [HKCategorySample]) -> Int {
        guard !samples.isEmpty else { return 0 }

        let sorted = samples.sorted { $0.startDate < $1.startDate }
        var mergedStart = sorted[0].startDate
        var mergedEnd   = sorted[0].endDate

        var totalSeconds: TimeInterval = 0
        for s in sorted.dropFirst() {
            if s.startDate <= mergedEnd {
                // Overlapping or touching — extend the current window if needed.
                if s.endDate > mergedEnd { mergedEnd = s.endDate }
            } else {
                // Gap — commit the current merged window and start a new one.
                totalSeconds += mergedEnd.timeIntervalSince(mergedStart)
                mergedStart = s.startDate
                mergedEnd   = s.endDate
            }
        }
        totalSeconds += mergedEnd.timeIntervalSince(mergedStart)

        return Int(totalSeconds / 60)
    }

    // MARK: - Heart rate

    private func fetchHeartRateSamples() async -> [HeartRateSample] {
        var melbCal = Calendar.current
        melbCal.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let startOfToday = melbCal.startOfDay(for: Date())
        let now          = Date()

        let predicate      = HKQuery.predicateForSamples(withStart: startOfToday,
                                                         end: now,
                                                         options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                              ascending: true)

        let rawSamples: [HKQuantitySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: heartRateType,
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sortDescriptor]) { _, results, error in
                if let error { print("⚕️ HR query error: \(error)") }
                cont.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }

        let unit = HKUnit(from: "count/min")
        return downsampleHeartRate(rawSamples, unit: unit)
    }

    /// Bins raw samples into 10-minute buckets (avg per bucket) so the chart
    /// stays readable even when the Watch records every few seconds.
    private func downsampleHeartRate(_ samples: [HKQuantitySample],
                                     unit: HKUnit) -> [HeartRateSample] {
        guard !samples.isEmpty else { return [] }
        let bucketSeconds: TimeInterval = 10 * 60
        var buckets: [TimeInterval: [Double]] = [:]

        for s in samples {
            let bpm = s.quantity.doubleValue(for: unit)
            let key = floor(s.startDate.timeIntervalSince1970 / bucketSeconds) * bucketSeconds
            buckets[key, default: []].append(bpm)
        }

        return buckets.keys.sorted().map { key in
            let avg = Int(buckets[key]!.reduce(0, +) / Double(buckets[key]!.count))
            return HeartRateSample(timestamp: Date(timeIntervalSince1970: key), bpm: avg)
        }
    }

    // MARK: - Mock fallback (used on simulator or when HealthKit is denied)

    private func makeMockData() -> HealthData {
        HealthData(sleepRecords:   makeSleepRecords(),
                   heartRateStats: HeartRateStats(samples: makeHeartRateSamples()))
    }

    private func makeSleepRecords() -> [SleepRecord] {
        let nights: [(Int, Int, Int, Int)] = [
            (375, 82, 95, 198),
            (452, 91, 108, 253),
            (318, 62, 79, 177),
            (488, 102, 121, 265),
            (404, 85, 100, 219),
            (432, 94, 110, 228),
            (360, 75, 90, 195),
        ]
        var melbCal = Calendar.current
        melbCal.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let today = melbCal.startOfDay(for: Date())

        return nights.enumerated().map { idx, n in
            let daysAgo  = nights.count - 1 - idx
            let wakeDate = melbCal.date(byAdding: .day, value: -daysAgo, to: today)!
            return SleepRecord(date: wakeDate,
                               totalMinutes: n.0, deepMinutes: n.1,
                               remMinutes:   n.2, coreMinutes: n.3)
        }
    }

    private func makeHeartRateSamples() -> [HeartRateSample] {
        let tz  = TimeZone(identifier: "Australia/Melbourne")!
        var cal = Calendar.current
        cal.timeZone = tz
        let today = cal.startOfDay(for: Date())
        let now   = Date()

        let pattern: [(Int, Int, Int)] = [
            ( 0, 01, 52), ( 0, 30, 51), ( 1,  0, 50), ( 1, 30, 49),
            ( 2,  0, 48), ( 2, 30, 49), ( 3,  0, 47), ( 3, 30, 48),
            ( 4,  0, 49), ( 4, 30, 50), ( 5,  0, 51), ( 5, 30, 53),
            ( 6,  0, 57), ( 6, 30, 63), ( 7,  0, 68), ( 7, 30, 72),
            ( 8,  0, 74), ( 8, 30, 76), ( 9,  0, 78), ( 9, 30, 80),
            (10,  0, 77), (10, 30, 75), (11,  0, 76), (11, 30, 74),
            (12,  0, 73), (12, 30, 79), (13,  0, 75), (13, 30, 72),
            (14,  0, 71), (14, 30, 73), (15,  0, 74), (15, 30, 72),
            (16,  0, 70), (16, 30, 69), (17,  0, 71), (17, 30, 75),
            (18,  0, 73), (18, 30, 70), (19,  0, 68), (19, 30, 66),
            (20,  0, 65), (20, 30, 63), (21,  0, 61), (21, 30, 60),
            (22,  0, 58), (22, 30, 57), (23,  0, 55), (23, 30, 54),
        ]

        return pattern.compactMap { h, m, bpm in
            guard let d = cal.date(bySettingHour: h, minute: m, second: 0, of: today),
                  d <= now else { return nil }
            return HeartRateSample(timestamp: d, bpm: max(40, bpm + Int.random(in: -3...3)))
        }
    }
}
