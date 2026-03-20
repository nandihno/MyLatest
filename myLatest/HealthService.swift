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
    private var distanceType: HKQuantityType {
        HKQuantityType(.distanceWalkingRunning)
    }
    private var workoutType: HKWorkoutType {
        HKObjectType.workoutType()
    }
    private var activeEnergyType: HKQuantityType {
        HKQuantityType(.activeEnergyBurned)
    }
    private var restingHeartRateType: HKQuantityType {
        HKQuantityType(.restingHeartRate)
    }
    private var vo2MaxType: HKQuantityType {
        HKQuantityType(.vo2Max)
    }

    // MARK: - Public API

    func fetchHealthData() async -> HealthData {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("⚕️ HealthKit not available — using mock data")
            let mock = makeMockData()
            print(debugSummary(mock, source: "MOCK"))
            return mock
        }

        do {
            try await store.requestAuthorization(
                toShare: [],
                read:    [sleepType, heartRateType, distanceType, workoutType,
                         activeEnergyType, restingHeartRateType, vo2MaxType]
            )
        } catch {
            print("⚕️ HealthKit auth error: \(error) — using mock data")
            let mock = makeMockData()
            print(debugSummary(mock, source: "MOCK"))
            return mock
        }

        // Fetch all datasets concurrently.
        async let sleepTask    = fetchSleepRecords()
        async let hrTask       = fetchHeartRateSamples()
        async let workoutTask  = fetchWorkoutData()
        async let briefTask    = fetchDailyBrief()
        let (sleepRecs, hrSamples, workouts, brief) = await (sleepTask, hrTask, workoutTask, briefTask)

        // Fall back to mock for sleep/HR if empty (permission may be denied for just one).
        // Workout data is always used as-is — zero sessions is valid (user just hasn't logged any).
        let finalSleep = sleepRecs.isEmpty  ? makeSleepRecords()     : sleepRecs
        let finalHR    = hrSamples.isEmpty  ? makeHeartRateSamples() : hrSamples

        let result = HealthData(
            sleepRecords:   finalSleep,
            heartRateStats: HeartRateStats(samples: finalHR),
            workoutData:    workouts,
            dailyBrief:     brief
        )
        print(debugSummary(result, source: "LIVE"))
        return result
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

    // MARK: - Daily Brief

    private func fetchDailyBrief() async -> DailyBrief {
        var melbCal = Calendar.current
        melbCal.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let now           = Date()
        let startOfToday  = melbCal.startOfDay(for: now)
        let startOfYday   = melbCal.date(byAdding: .day, value: -1, to: startOfToday)!

        // Same day last week
        let lastWeekToday     = melbCal.date(byAdding: .day, value: -7, to: startOfToday)!
        let lastWeekTomorrow  = melbCal.date(byAdding: .day, value: -6, to: startOfToday)!

        async let todayWorkoutsTask    = fetchWorkouts(from: startOfToday, to: now)
        async let lastWeekWorkoutsTask = fetchWorkouts(from: lastWeekToday, to: lastWeekTomorrow)
        async let energyTask           = fetchActiveEnergy(from: startOfYday, to: startOfToday)
        async let restHRTask           = fetchRestingHeartRate()
        async let vo2Task              = fetchVO2MaxSamples()
        let (todayWorkouts, lastWeekWorkouts, energy, restHR, vo2) =
            await (todayWorkoutsTask, lastWeekWorkoutsTask, energyTask, restHRTask, vo2Task)

        let comparisons = buildWorkoutComparisons(today: todayWorkouts, lastWeek: lastWeekWorkouts)

        return DailyBrief(
            workoutComparisons:    comparisons,
            activeEnergyBurnedCal: energy,
            restingHeartRate:      restHR,
            vo2MaxSamples:         vo2
        )
    }

    /// Builds per-workout-type comparisons between today and the same day last week.
    private func buildWorkoutComparisons(today: [HKWorkout], lastWeek: [HKWorkout]) -> [WorkoutComparison] {
        let energyUnit = HKUnit.kilocalorie()

        // Aggregate by workout name
        func aggregate(_ workouts: [HKWorkout]) -> [String: (minutes: Int, calories: Int)] {
            var dict: [String: (minutes: Int, calories: Int)] = [:]
            for w in workouts {
                let name = workoutTypeName(w.workoutActivityType)
                let mins = Int(w.duration / 60)
                let cals = Int(w.totalEnergyBurned?.doubleValue(for: energyUnit) ?? 0)
                let existing = dict[name] ?? (0, 0)
                dict[name] = (existing.minutes + mins, existing.calories + cals)
            }
            return dict
        }

        let todayAgg    = aggregate(today)
        let lastWeekAgg = aggregate(lastWeek)

        // All workout types from both days, maintaining order (today first)
        var seen = Set<String>()
        var orderedNames: [String] = []
        for name in today.map({ workoutTypeName($0.workoutActivityType) }) {
            if seen.insert(name).inserted { orderedNames.append(name) }
        }
        for name in lastWeek.map({ workoutTypeName($0.workoutActivityType) }) {
            if seen.insert(name).inserted { orderedNames.append(name) }
        }

        return orderedNames.map { name in
            let t = todayAgg[name]
            let l = lastWeekAgg[name]
            return WorkoutComparison(
                name:            name,
                todayMinutes:    t?.minutes ?? 0,
                todayCalories:   t?.calories ?? 0,
                lastWeekMinutes: l?.minutes  // nil if not done last week
            )
        }
    }

    /// Maps HKWorkoutActivityType to a human-readable name.
    private func workoutTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking:                       return "Walking"
        case .running:                       return "Running"
        case .hiking:                        return "Hiking"
        case .cycling:                       return "Cycling"
        case .yoga:                          return "Yoga"
        case .pilates:                       return "Pilates"
        case .coreTraining:                  return "Core Training"
        case .traditionalStrengthTraining:   return "Strength Training"
        case .functionalStrengthTraining:    return "Functional Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .crossTraining:                 return "Cross Training"
        case .mixedCardio:                   return "Mixed Cardio"
        case .elliptical:                    return "Elliptical"
        case .stairClimbing:                 return "Stair Climbing"
        case .rowing:                        return "Rowing"
        case .flexibility:                   return "Flexibility"
        case .mindAndBody:                   return "Mind & Body"
        case .swimming:                      return "Swimming"
        case .dance:                         return "Dance"
        default:                             return "Workout"
        }
    }

    /// Fetches yesterday's total active energy burned (kcal).
    private func fetchActiveEnergy(from start: Date, to end: Date) async -> Int {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                     options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: activeEnergyType,
                                       quantitySamplePredicate: predicate,
                                       options: .cumulativeSum) { _, stats, error in
                if let error { print("⚕️ Active energy query error: \(error)") }
                let kcal = stats?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                cont.resume(returning: Int(kcal))
            }
            store.execute(q)
        }
    }

    /// Fetches the most recent resting heart rate value.
    private func fetchRestingHeartRate() async -> Int? {
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                               ascending: false)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType:     restingHeartRateType,
                                  predicate:      nil,
                                  limit:          1,
                                  sortDescriptors: [sortDescriptor]) { _, results, error in
                if let error { print("⚕️ Resting HR query error: \(error)") }
                guard let sample = results?.first as? HKQuantitySample else {
                    cont.resume(returning: nil)
                    return
                }
                let bpm = Int(sample.quantity.doubleValue(for: HKUnit(from: "count/min")))
                cont.resume(returning: bpm)
            }
            store.execute(q)
        }
    }

    /// Fetches VO2 Max samples from the last 4 weeks for trend display.
    private func fetchVO2MaxSamples() async -> [VO2MaxSample] {
        var melbCal = Calendar.current
        melbCal.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let now   = Date()
        let start = melbCal.date(byAdding: .weekOfYear, value: -4, to: now)!

        let predicate      = HKQuery.predicateForSamples(withStart: start, end: now,
                                                          options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                               ascending: true)

        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType:     vo2MaxType,
                                  predicate:      predicate,
                                  limit:          HKObjectQueryNoLimit,
                                  sortDescriptors: [sortDescriptor]) { _, results, error in
                if let error { print("⚕️ VO2 Max query error: \(error)") }
                let samples = (results as? [HKQuantitySample])?.map { s in
                    VO2MaxSample(
                        date:  s.startDate,
                        value: s.quantity.doubleValue(for: HKUnit(from: "ml/kg*min"))
                    )
                } ?? []
                cont.resume(returning: samples)
            }
            store.execute(q)
        }
    }

    // MARK: - Mock fallback (used on simulator or when HealthKit is denied)

    private func makeMockData() -> HealthData {
        HealthData(sleepRecords:   makeSleepRecords(),
                   heartRateStats: HeartRateStats(samples: makeHeartRateSamples()),
                   workoutData:    makeWorkoutData(),
                   dailyBrief:     makeDailyBrief())
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

    // MARK: - Workouts

    private func fetchWorkoutData() async -> WorkoutData {
        // Melbourne-timezone calendar with Monday as the first weekday.
        // Must be a `let` so it's safe to capture in concurrent async-let tasks.
        var _cal = Calendar(identifier: .gregorian)
        _cal.timeZone    = TimeZone(identifier: "Australia/Melbourne")!
        _cal.firstWeekday = 2   // Monday
        let melbCal = _cal

        let now           = Date()
        // Monday midnight that opened the current ISO week (Melbourne time).
        let weekComps     = melbCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let thisWeekStart = melbCal.date(from: weekComps)!
        let lastWeekStart = melbCal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart)!

        // Fetch distance and workouts for both weeks concurrently.
        async let thisDistTask = fetchDailyDistances(from: thisWeekStart, to: now,              calendar: melbCal)
        async let lastDistTask = fetchDailyDistances(from: lastWeekStart, to: thisWeekStart, calendar: melbCal)
        async let thisWorkTask = fetchWorkouts(from: thisWeekStart, to: now)
        async let lastWorkTask = fetchWorkouts(from: lastWeekStart, to: thisWeekStart)
        let (thisDist, lastDist, thisWork, lastWork) = await (thisDistTask, lastDistTask, thisWorkTask, lastWorkTask)

        // Build the 7-day distance array (Mon → Sun).
        let days: [WeeklyDistanceDay] = (0..<7).map { i in
            let dayDate = melbCal.date(byAdding: .day, value: i, to: thisWeekStart)!
            return WeeklyDistanceDay(
                weekdayIndex: i,
                weekdayLabel: dayDate.formatted(.dateTime.weekday(.abbreviated)),
                thisWeekKm:   thisDist[i] ?? 0,
                lastWeekKm:   lastDist[i] ?? 0
            )
        }

        let distanceData = WeeklyDistanceData(
            days:            days,
            thisWeekTotalKm: days.reduce(0) { $0 + $1.thisWeekKm },
            lastWeekTotalKm: days.reduce(0) { $0 + $1.lastWeekKm },
            weekStartDate:   thisWeekStart
        )

        let activities: [ActivityWeekSummary] = ActivityCategory.allCases.map { cat in
            let thisFiltered = thisWork.filter { activityCategory(for: $0) == cat }
            let lastFiltered = lastWork.filter { activityCategory(for: $0) == cat }
            return ActivityWeekSummary(
                category:         cat,
                thisWeekMinutes:  Int(thisFiltered.reduce(0) { $0 + $1.duration } / 60),
                thisWeekSessions: thisFiltered.count,
                lastWeekMinutes:  Int(lastFiltered.reduce(0) { $0 + $1.duration } / 60),
                lastWeekSessions: lastFiltered.count
            )
        }

        return WorkoutData(weeklyDistance: distanceData, activities: activities)
    }

    /// Fetches cumulative walking/running distance per weekday-index (0=Mon…6=Sun)
    /// for the given time window, using HealthKit's statistics collection so overlapping
    /// sources (iPhone + Watch) are automatically deduplicated.
    private func fetchDailyDistances(from start: Date, to end: Date,
                                     calendar: Calendar) async -> [Int: Double] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                    options: .strictStartDate)
        // Anchor daily buckets to midnight at the start of the window.
        var anchorComps    = calendar.dateComponents([.year, .month, .day], from: start)
        anchorComps.hour   = 0; anchorComps.minute = 0; anchorComps.second = 0
        let anchor         = calendar.date(from: anchorComps) ?? start

        return await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType:            distanceType,
                quantitySamplePredicate: predicate,
                options:                 .cumulativeSum,
                anchorDate:              anchor,
                intervalComponents:      DateComponents(day: 1)
            )
            q.initialResultsHandler = { _, results, error in
                if let error { print("⚕️ Distance stats error: \(error)") }
                guard let results else { cont.resume(returning: [:]); return }

                var daily: [Int: Double] = [:]
                results.enumerateStatistics(from: start, to: end) { stats, _ in
                    guard let sum = stats.sumQuantity() else { return }
                    let km      = sum.doubleValue(for: HKUnit.meterUnit(with: .kilo))
                    let weekday = calendar.component(.weekday, from: stats.startDate)
                    // weekday: 1=Sun 2=Mon … 7=Sat  →  index: 0=Mon … 6=Sun
                    daily[(weekday - 2 + 7) % 7] = km
                }
                cont.resume(returning: daily)
            }
            store.execute(q)
        }
    }

    /// Returns all HKWorkout samples in the given window, sorted by start date.
    private func fetchWorkouts(from start: Date, to end: Date) async -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                    options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType:    workoutType,
                                  predicate:     predicate,
                                  limit:         HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, results, error in
                if let error { print("⚕️ Workout query error: \(error)") }
                cont.resume(returning: (results as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }

    /// Maps a HealthKit workout to one of the four activity categories, or nil if uncategorised.
    private func activityCategory(for workout: HKWorkout) -> ActivityCategory? {
        switch workout.workoutActivityType {
        case .walking, .running, .hiking:
            return .walking
        case .coreTraining, .yoga, .pilates, .flexibility, .mindAndBody:
            return .core
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            return .strength
        case .highIntensityIntervalTraining, .crossTraining, .mixedCardio,
             .elliptical, .stairClimbing, .cycling, .rowing:
            return .gym
        default:
            return nil
        }
    }

    // MARK: - Mock workout data (simulator / HealthKit unavailable)

    private func makeWorkoutData() -> WorkoutData {
        var melbCal = Calendar(identifier: .gregorian)
        melbCal.timeZone    = TimeZone(identifier: "Australia/Melbourne")!
        melbCal.firstWeekday = 2

        let now           = Date()
        let weekComps     = melbCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let thisWeekStart = melbCal.date(from: weekComps)!

        // Mock daily km: Mon … Sun
        let thisKm: [Double] = [4.2, 2.8, 5.5, 3.1, 0.0, 0.0, 0.0]
        let lastKm: [Double] = [3.0, 0.0, 4.5, 2.2, 5.8, 6.2, 1.5]

        let days: [WeeklyDistanceDay] = (0..<7).map { i in
            let d = melbCal.date(byAdding: .day, value: i, to: thisWeekStart)!
            return WeeklyDistanceDay(
                weekdayIndex: i,
                weekdayLabel: d.formatted(.dateTime.weekday(.abbreviated)),
                thisWeekKm:   thisKm[i],
                lastWeekKm:   lastKm[i]
            )
        }

        let distData = WeeklyDistanceData(
            days:            days,
            thisWeekTotalKm: thisKm.reduce(0, +),
            lastWeekTotalKm: lastKm.reduce(0, +),
            weekStartDate:   thisWeekStart
        )

        let activities: [ActivityWeekSummary] = [
            ActivityWeekSummary(category: .walking,  thisWeekMinutes: 135, thisWeekSessions: 4,
                                                     lastWeekMinutes: 165, lastWeekSessions: 4),
            ActivityWeekSummary(category: .core,     thisWeekMinutes:  60, thisWeekSessions: 2,
                                                     lastWeekMinutes:  90, lastWeekSessions: 3),
            ActivityWeekSummary(category: .strength, thisWeekMinutes: 120, thisWeekSessions: 2,
                                                     lastWeekMinutes: 165, lastWeekSessions: 3),
            ActivityWeekSummary(category: .gym,      thisWeekMinutes:  45, thisWeekSessions: 1,
                                                     lastWeekMinutes:  90, lastWeekSessions: 2),
        ]

        return WorkoutData(weeklyDistance: distData, activities: activities)
    }

    private func makeDailyBrief() -> DailyBrief {
        var melbCal = Calendar.current
        melbCal.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let today = melbCal.startOfDay(for: Date())

        let mockVO2: [VO2MaxSample] = (-3...0).map { weeksAgo in
            VO2MaxSample(
                date:  melbCal.date(byAdding: .weekOfYear, value: weeksAgo, to: today)!,
                value: 38.2 + Double(weeksAgo + 3) * 0.5 + Double.random(in: -0.3...0.3)
            )
        }

        return DailyBrief(
            workoutComparisons: [
                WorkoutComparison(name: "Walking",           todayMinutes: 42, todayCalories: 185, lastWeekMinutes: 35),
                WorkoutComparison(name: "Strength Training", todayMinutes: 55, todayCalories: 310, lastWeekMinutes: 60),
                WorkoutComparison(name: "HIIT",              todayMinutes: 30, todayCalories: 280, lastWeekMinutes: nil),
            ],
            activeEnergyBurnedCal: 520,
            restingHeartRate:      58,
            vo2MaxSamples:         mockVO2
        )
    }

    // MARK: - Debug summary

    /// Builds a human-readable console summary of all data currently shown in the Health tab.
    func debugSummary(_ data: HealthData, source: String) -> String {
        var lines: [String] = []
        let now = Date()
        let ts  = now.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())

        lines.append("")
        lines.append("╔══════════════════════════════════════════════════")
        lines.append("║  Health Tab — Data Summary  [\(source)]")
        lines.append("║  Generated: \(ts)")
        lines.append("╠══════════════════════════════════════════════════")

        // ── Distance ────────────────────────────────────────────────────
        let wd = data.workoutData.weeklyDistance
        let wStart = wd.weekStartDate.formatted(.dateTime.day().month(.abbreviated))
        lines.append("║")
        lines.append("║  📍 DISTANCE   (week from \(wStart))")
        lines.append("║  ─────────────────────────────────────")
        for day in wd.days {
            let thisStr = String(format: "%.2f km", day.thisWeekKm)
            let lastStr = String(format: "%.2f km", day.lastWeekKm)
            let flag    = day.thisWeekKm > 0 || day.lastWeekKm > 0 ? "" : "  (rest)"
            lines.append("║   \(day.weekdayLabel.padding(toLength: 3, withPad: " ", startingAt: 0))  this wk: \(thisStr.padding(toLength: 8, withPad: " ", startingAt: 0))  last wk: \(lastStr)\(flag)")
        }
        let distDiff   = wd.thisWeekTotalKm - wd.lastWeekTotalKm
        let distPctStr = wd.lastWeekTotalKm > 0
            ? String(format: " (%+.0f%%)", distDiff / wd.lastWeekTotalKm * 100)
            : ""
        lines.append("║   ─────────────────────────────────────")
        lines.append("║   Total  this wk: \(String(format: "%.2f km", wd.thisWeekTotalKm))   last wk: \(String(format: "%.2f km", wd.lastWeekTotalKm))\(distPctStr)")

        // ── Activity ─────────────────────────────────────────────────────
        lines.append("║")
        lines.append("║  🏃 ACTIVITY")
        lines.append("║  ─────────────────────────────────────")
        for act in data.workoutData.activities {
            let name     = act.category.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            let thisSess = "\(act.thisWeekSessions)×\(ActivityWeekSummary.durationLabel(act.thisWeekMinutes))"
            let lastSess = "\(act.lastWeekSessions)×\(ActivityWeekSummary.durationLabel(act.lastWeekMinutes))"
            var delta = ""
            if act.lastWeekMinutes > 0 {
                let pct = Int((Double(act.thisWeekMinutes - act.lastWeekMinutes) / Double(act.lastWeekMinutes)) * 100)
                delta = String(format: "  (%+d%%)", pct)
            } else if act.thisWeekSessions > 0 {
                delta = "  (new)"
            }
            let thisStr = thisSess.padding(toLength: 14, withPad: " ", startingAt: 0)
            lines.append("║   \(name)  this wk: \(thisStr) last wk: \(lastSess)\(delta)")
        }

        // ── Sleep ────────────────────────────────────────────────────────
        let sleepTotal = data.sleepRecords.reduce(0) { $0 + $1.totalMinutes }
        let sleepAvgH  = data.sleepRecords.isEmpty ? 0.0
                         : Double(sleepTotal) / Double(data.sleepRecords.count) / 60.0
        lines.append("║")
        lines.append("║  😴 SLEEP   (7-day avg: \(String(format: "%.1fh", sleepAvgH)))")
        lines.append("║  ─────────────────────────────────────")
        for rec in data.sleepRecords {
            let dateStr  = rec.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            let stageStr = "deep \(rec.deepMinutes)m  REM \(rec.remMinutes)m  core \(rec.coreMinutes)m"
            lines.append("║   \(dateStr.padding(toLength: 12, withPad: " ", startingAt: 0))  \(rec.durationLabel.padding(toLength: 8, withPad: " ", startingAt: 0))  [\(stageStr)]")
        }

        // ── Heart Rate ───────────────────────────────────────────────────
        let hr = data.heartRateStats
        lines.append("║")
        lines.append("║  ❤️  HEART RATE   (today)")
        lines.append("║  ─────────────────────────────────────")
        lines.append("║   Latest: \(hr.latest.map { "\($0) BPM" } ?? "n/a")")
        lines.append("║   Min: \(hr.min) BPM   Avg: \(hr.average) BPM   Max: \(hr.max) BPM")
        lines.append("║   Samples: \(hr.samples.count)")

        // ── Daily Brief ────────────────────────────────────────────────
        let db = data.dailyBrief
        lines.append("║")
        lines.append("║  📋 DAILY BRIEF")
        lines.append("║  ─────────────────────────────────────")
        lines.append("║   Active Energy (yesterday): \(db.activeEnergyBurnedCal) kcal")
        lines.append("║   Resting Heart Rate: \(db.restingHeartRate.map { "\($0) BPM" } ?? "n/a")")
        lines.append("║   VO2 Max (latest): \(db.vo2MaxLatest.map { String(format: "%.1f mL/kg/min", $0) } ?? "n/a")")
        if db.vo2MaxSamples.count >= 2 {
            let oldest = db.vo2MaxSamples.first!
            let newest = db.vo2MaxSamples.last!
            let trend  = newest.value - oldest.value
            let arrow  = trend > 0.2 ? "↑" : trend < -0.2 ? "↓" : "→"
            lines.append("║   VO2 Max trend (\(db.vo2MaxSamples.count) readings, 4 weeks): \(arrow) \(String(format: "%+.1f", trend))")
        }
        if db.workoutComparisons.isEmpty {
            lines.append("║   Today's workouts: none yet")
        } else {
            lines.append("║   Today's workouts vs same day last week:")
            for w in db.workoutComparisons {
                let todayStr = WorkoutComparison.formatDuration(w.todayMinutes)
                let lastStr  = w.lastWeekDurationLabel
                var delta = ""
                if let pct = w.changePercent {
                    delta = pct == 0 ? " (≈ same)" : String(format: " (%+d%%)", pct)
                } else if w.lastWeekMinutes == nil {
                    delta = " (new — N/A last wk)"
                }
                lines.append("║     • \(w.name): today \(todayStr), \(w.todayCalories) kcal | last wk \(lastStr)\(delta)")
            }
            lines.append("║   Today total: \(db.todayDurationLabel), \(db.todayTotalCalories) kcal")
        }

        lines.append("╚══════════════════════════════════════════════════")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Returns a formatted text summary suitable for Claude AI health analysis.
    func summaryText(for data: HealthData) -> String {
        debugSummary(data, source: "LIVE")
    }
}
