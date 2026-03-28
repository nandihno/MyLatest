# Lessons Learned

## HealthKit Distance Queries: Indoor Workout Source-Preference Quirk

**Date:** 2026-03-28
**File:** `myLatest/HealthService.swift`

### Problem

Indoor treadmill workouts (walking and running) recorded by Apple Watch were showing significantly lower distance than expected in the weekly distance chart. A 20-minute indoor run showing 2.68 km on the Watch was only contributing ~1.20 km to the daily total.

### Root Cause

`HKStatisticsCollectionQuery` with `.cumulativeSum` applies **source-preference deduplication** that behaves inconsistently depending on the query's date range:

- When querying a **full week** with daily buckets, the collection query preferred the **iPhone** as the distance source. Since the iPhone barely moves during a treadmill workout, indoor Watch distance was largely excluded from the daily totals.
- When querying a **narrow window** (e.g. the 21-minute workout window), the same collection query returned the **Watch's** 2.68 km — because only Watch data existed for that period.

This inconsistency made the original "supplement" approach unreliable. The supplement logic compared `workoutKm` (from workout statistics) against `sampledKm` (from a narrow-window query). Since both returned ~2.68 km, `missingKm` was calculated as 0, and no supplement was added — even though the base daily query only captured ~1.20 km.

### Key Insight

**You cannot reliably compare two `HKStatisticsCollectionQuery` results (or an `HKStatisticsQuery` vs `HKStatisticsCollectionQuery`) across different date ranges to determine "missing" distance.** HealthKit's source-preference resolution is a black box that varies with query parameters.

### Solution

For indoor walking/running workouts (identified by `HKMetadataKeyIndoorWorkout == true`), use the **workout's own distance** (from `workout.statistics(for:)` or the deprecated `workout.totalDistance`) as the authoritative source. Add the full workout distance as a supplement without comparing against sampled distance.

```swift
// DO THIS — trust the workout's distance for indoor sessions
let workoutKm = distanceQuantity.doubleValue(for: weeklyDistanceUnit)
addDistance(workoutKm, ...)

// DON'T DO THIS — the comparison is unreliable due to source-preference quirks
let sampledKm = await fetchDistanceSampleTotal(...)
let missingKm = workoutKm - sampledKm  // can be 0 even when base missed the data
```

This may cause minor double-counting with iPhone pedometer steps recorded during the workout (~0.3-0.5 km), but that is negligible compared to missing 2+ km of treadmill distance.

### Other HealthKit Deprecations (iOS 18+)

- `HKWorkout.totalDistance` — use `workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()` with a fallback to `totalDistance` for older workouts.
- `HKWorkout.totalEnergyBurned` — use `workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()` with a fallback to `totalEnergyBurned`.

### How to Identify Indoor Workouts

Apple Watch sets the `HKMetadataKeyIndoorWorkout` metadata key to `true` for indoor workout sessions. Filter with:

```swift
workout.workoutActivityType == .walking || workout.workoutActivityType == .running
workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool == true
```

### Debugging Tips

When diagnosing HealthKit distance discrepancies:

1. Log `workout.statistics(for:)` and the deprecated `totalDistance` to confirm the workout object has distance data.
2. Log the base `HKStatisticsCollectionQuery` results per day-index to see what the base captures.
3. Compare narrow-window queries against full-range queries — they may disagree due to source preference.
4. Check `workout.metadata` keys to confirm indoor flag and other metadata are present.
