//
//  GTFSDatabase.swift
//  myLatest
//
//  Downloads the TransLink SEQ GTFS static ZIP, extracts CSV files,
//  and imports them into a local SQLite database for efficient querying.
//  Uses the built-in SQLite3 C API (no external dependencies).
//

import Foundation
import SQLite3
import CoreLocation
import Compression

// MARK: - Static GTFS row types

struct GTFSStop {
    let stopId: String
    let stopName: String
    let stopCode: String?
    let stopLat: Double
    let stopLon: Double
    let locationType: Int     // 0 = stop/platform, 1 = station
    let parentStation: String?
}

struct GTFSRoute {
    let routeId: String
    let routeShortName: String
    let routeLongName: String
    let routeType: Int         // 3 = bus
}

struct GTFSStopTime {
    let tripId: String
    let stopId: String
    let arrivalTime: String    // "HH:MM:SS" (may exceed 24:00)
    let departureTime: String
    let stopSequence: Int
    let arrivalSeconds: Int    // parsed total seconds from midnight
    let departureSeconds: Int
}

struct GTFSTrip {
    let tripId: String
    let routeId: String
    let serviceId: String
    let tripHeadsign: String?
    let directionId: Int
}

struct GTFSCalendar {
    let serviceId: String
    let monday: Bool
    let tuesday: Bool
    let wednesday: Bool
    let thursday: Bool
    let friday: Bool
    let saturday: Bool
    let sunday: Bool
    let startDate: String    // YYYYMMDD
    let endDate: String
}

struct GTFSCalendarDate {
    let serviceId: String
    let date: String          // YYYYMMDD
    let exceptionType: Int    // 1 = added, 2 = removed
}

// MARK: - Download Progress (observable from UI)

@MainActor
@Observable
final class GTFSDownloadProgress {
    static let shared = GTFSDownloadProgress()

    var isActive = false
    var stage: String = ""
    var detail: String = ""

    func update(stage: String, detail: String = "") {
        self.isActive = true
        self.stage = stage
        self.detail = detail
    }

    func finish() {
        self.isActive = false
        self.stage = ""
        self.detail = ""
    }
}

// MARK: - Database Manager

actor GTFSDatabase {
    static let shared = GTFSDatabase()

    private let gtfsZipURL = URL(string: "https://gtfsrt.api.translink.com.au/GTFS/SEQ_GTFS.zip")!
    private var db: OpaquePointer?
    private var isImported = false

    private var dbPath: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("gtfs_seq.sqlite3").path
    }

    private var extractDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("gtfs_extracted", isDirectory: true)
    }

    // MARK: - Public API

    /// Returns true if the database file exists and has data, without triggering a download.
    func isDatabaseReady() -> Bool {
        if isImported && db != nil { return true }
        guard FileManager.default.fileExists(atPath: dbPath) else { return false }
        // Try opening and checking
        do {
            try openDB()
            let count = queryCount("SELECT COUNT(*) FROM stops")
            if count > 0 {
                isImported = true
                return true
            }
        } catch {}
        return false
    }

    /// Ensures the database is ready. Downloads GTFS ZIP if needed, imports into SQLite.
    func ensureReady() async throws {
        if isImported && db != nil { return }

        // Check if database already exists and has data
        if FileManager.default.fileExists(atPath: dbPath) {
            try openDB()
            let count = queryCount("SELECT COUNT(*) FROM stops")
            if count > 0 {
                isImported = true
                return
            }
        }

        // Need to download and import
        try await downloadAndImport()
    }

    /// Deletes the database and resets state so the next `ensureReady()` re-downloads everything.
    func resetDatabase() throws {
        // Close existing connection
        if let db {
            sqlite3_close(db)
        }
        db = nil
        isImported = false

        let fm = FileManager.default
        // Remove SQLite file
        if fm.fileExists(atPath: dbPath) {
            try fm.removeItem(atPath: dbPath)
        }
        // Remove extracted CSV directory
        if fm.fileExists(atPath: extractDir.path) {
            try fm.removeItem(at: extractDir)
        }
    }

    /// Search bus stops by name (case-insensitive LIKE query).
    func searchBusStops(name: String, limit: Int = 30) throws -> [BusStopSearchResult] {
        guard let db else { throw GTFSDBError.notReady }

        let sql = """
            SELECT stop_id, stop_name, stop_code, stop_lat, stop_lon
            FROM stops
            WHERE route_type = 3
              AND location_type = 0
              AND stop_name LIKE ?
            ORDER BY stop_name ASC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(name)%"
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [BusStopSearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(BusStopSearchResult(
                stopId: String(cString: sqlite3_column_text(stmt, 0)),
                stopName: String(cString: sqlite3_column_text(stmt, 1)),
                stopCode: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                latitude: sqlite3_column_double(stmt, 3),
                longitude: sqlite3_column_double(stmt, 4)
            ))
        }
        return results
    }

    /// Get departures for specific stop IDs (used for favourite stops, no proximity needed).
    func departuresForFavourites(stopIds: [String], afterSeconds: Int, limitPerStop: Int = 10) throws -> [ScheduledDeparture] {
        // Reuses the same departures method
        return try departures(forStopIds: stopIds, afterSeconds: afterSeconds, limitPerStop: limitPerStop)
    }

    /// Check if GTFS data needs refresh (older than 7 days).
    func needsRefresh() -> Bool {
        guard FileManager.default.fileExists(atPath: dbPath) else { return true }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
              let modified = attrs[.modificationDate] as? Date else { return true }
        return abs(modified.timeIntervalSinceNow) > 7 * 24 * 3600
    }

    /// Find bus stops within a bounding box (for map view). Returns up to `limit` stops.
    func stopsInRegion(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, limit: Int = 100) throws -> [GTFSStop] {
        guard let db else { throw GTFSDBError.notReady }

        let sql = """
            SELECT stop_id, stop_name, stop_code, stop_lat, stop_lon, location_type, parent_station
            FROM stops
            WHERE route_type = 3
              AND location_type = 0
              AND stop_lat BETWEEN ? AND ?
              AND stop_lon BETWEEN ? AND ?
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, minLat)
        sqlite3_bind_double(stmt, 2, maxLat)
        sqlite3_bind_double(stmt, 3, minLon)
        sqlite3_bind_double(stmt, 4, maxLon)
        sqlite3_bind_int(stmt, 5, Int32(limit))

        var results: [GTFSStop] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(GTFSStop(
                stopId: String(cString: sqlite3_column_text(stmt, 0)),
                stopName: String(cString: sqlite3_column_text(stmt, 1)),
                stopCode: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                stopLat: sqlite3_column_double(stmt, 3),
                stopLon: sqlite3_column_double(stmt, 4),
                locationType: Int(sqlite3_column_int(stmt, 5)),
                parentStation: sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            ))
        }
        return results
    }

    /// Find bus stops within `radiusMeters` of the given coordinate.
    func nearbyBusStops(latitude: Double, longitude: Double, radiusMeters: Double = 300) throws -> [(stop: GTFSStop, distanceMeters: Double)] {
        guard let db else { throw GTFSDBError.notReady }

        // Approximate bounding box (1 degree latitude ≈ 111km)
        let latDelta = radiusMeters / 111_000.0
        let lonDelta = radiusMeters / (111_000.0 * cos(latitude * .pi / 180.0))

        let sql = """
            SELECT stop_id, stop_name, stop_code, stop_lat, stop_lon, location_type, parent_station
            FROM stops
            WHERE route_type = 3
              AND location_type = 0
              AND stop_lat BETWEEN ? AND ?
              AND stop_lon BETWEEN ? AND ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, latitude - latDelta)
        sqlite3_bind_double(stmt, 2, latitude + latDelta)
        sqlite3_bind_double(stmt, 3, longitude - lonDelta)
        sqlite3_bind_double(stmt, 4, longitude + lonDelta)

        let userLocation = CLLocation(latitude: latitude, longitude: longitude)
        var results: [(GTFSStop, Double)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let stop = GTFSStop(
                stopId: String(cString: sqlite3_column_text(stmt, 0)),
                stopName: String(cString: sqlite3_column_text(stmt, 1)),
                stopCode: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                stopLat: sqlite3_column_double(stmt, 3),
                stopLon: sqlite3_column_double(stmt, 4),
                locationType: Int(sqlite3_column_int(stmt, 5)),
                parentStation: sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            )
            let stopLocation = CLLocation(latitude: stop.stopLat, longitude: stop.stopLon)
            let distance = userLocation.distance(from: stopLocation)
            if distance <= radiusMeters {
                results.append((stop, distance))
            }
        }

        return results.sorted { $0.1 < $1.1 }
    }

    /// Get scheduled departures for a set of stop IDs, filtered to today's active services.
    func departures(forStopIds stopIds: [String], afterSeconds: Int, limitPerStop: Int = 10) throws -> [ScheduledDeparture] {
        guard let db else { throw GTFSDBError.notReady }
        guard !stopIds.isEmpty else { return [] }

        let activeServiceIds = try todayActiveServiceIds()
        guard !activeServiceIds.isEmpty else { return [] }

        let stopPlaceholders = stopIds.map { _ in "?" }.joined(separator: ",")
        let servicePlaceholders = activeServiceIds.map { _ in "?" }.joined(separator: ",")

        let sql = """
            SELECT st.trip_id, st.stop_id, st.departure_time, st.departure_seconds, st.stop_sequence,
                   t.route_id, t.trip_headsign, t.direction_id,
                   r.route_short_name, r.route_long_name,
                   s.stop_name
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN routes r ON t.route_id = r.route_id
            JOIN stops s ON st.stop_id = s.stop_id
            WHERE st.stop_id IN (\(stopPlaceholders))
              AND t.service_id IN (\(servicePlaceholders))
              AND st.departure_seconds >= ?
              AND r.route_type = 3
            ORDER BY st.departure_seconds ASC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for stopId in stopIds {
            sqlite3_bind_text(stmt, idx, (stopId as NSString).utf8String, -1, nil)
            idx += 1
        }
        for serviceId in activeServiceIds {
            sqlite3_bind_text(stmt, idx, (serviceId as NSString).utf8String, -1, nil)
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(afterSeconds))
        idx += 1
        sqlite3_bind_int(stmt, idx, Int32(limitPerStop * stopIds.count))

        var results: [ScheduledDeparture] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(ScheduledDeparture(
                tripId: String(cString: sqlite3_column_text(stmt, 0)),
                stopId: String(cString: sqlite3_column_text(stmt, 1)),
                departureTime: String(cString: sqlite3_column_text(stmt, 2)),
                departureSeconds: Int(sqlite3_column_int(stmt, 3)),
                stopSequence: Int(sqlite3_column_int(stmt, 4)),
                routeId: String(cString: sqlite3_column_text(stmt, 5)),
                tripHeadsign: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
                directionId: Int(sqlite3_column_int(stmt, 7)),
                routeShortName: String(cString: sqlite3_column_text(stmt, 8)),
                routeLongName: String(cString: sqlite3_column_text(stmt, 9)),
                stopName: String(cString: sqlite3_column_text(stmt, 10))
            ))
        }

        return results
    }

    /// Structured departure result combining static GTFS data.
    struct ScheduledDeparture {
        let tripId: String
        let stopId: String
        let departureTime: String     // "HH:MM:SS"
        let departureSeconds: Int
        let stopSequence: Int
        let routeId: String
        let tripHeadsign: String?
        let directionId: Int
        let routeShortName: String
        let routeLongName: String
        let stopName: String
    }

    // MARK: - Download & Import

    private func downloadAndImport() async throws {
        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Downloading bus schedule data…", detail: "~26 MB from TransLink") }
        print("📦 Downloading SEQ GTFS ZIP…")
        let (zipURL, _) = try await URLSession.shared.download(from: gtfsZipURL)

        // Move to a known location
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let localZip = caches.appendingPathComponent("SEQ_GTFS.zip")
        try? FileManager.default.removeItem(at: localZip)
        try FileManager.default.moveItem(at: zipURL, to: localZip)

        // Extract
        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Extracting schedule files…") }
        print("📦 Extracting GTFS data…")
        let extractTo = self.extractDir
        try? FileManager.default.removeItem(at: extractTo)
        try FileManager.default.createDirectory(at: extractTo, withIntermediateDirectories: true)
        try extractZip(at: localZip, to: extractTo)

        // Import into SQLite
        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Building local database…", detail: "Importing stops, routes & timetables") }
        print("📦 Importing GTFS into SQLite…")
        try? FileManager.default.removeItem(atPath: dbPath)
        try openDB()
        try createTables()
        try await importCSVFiles(from: extractTo)

        isImported = true
        await MainActor.run { GTFSDownloadProgress.shared.finish() }
        print("✅ GTFS database ready.")

        // Cleanup extracted CSVs (keep ZIP for potential re-extract)
        try? FileManager.default.removeItem(at: extractTo)
    }

    // MARK: - SQLite helpers

    private func openDB() throws {
        if db != nil { return }
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw GTFSDBError.openFailed
        }
        // Performance pragmas
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("PRAGMA cache_size = -8000")  // 8MB cache
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func queryCount(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func createTables() throws {
        let sqls = [
            """
            CREATE TABLE IF NOT EXISTS stops (
                stop_id TEXT PRIMARY KEY,
                stop_name TEXT NOT NULL,
                stop_code TEXT,
                stop_lat REAL NOT NULL,
                stop_lon REAL NOT NULL,
                location_type INTEGER DEFAULT 0,
                parent_station TEXT,
                route_type INTEGER DEFAULT -1
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS routes (
                route_id TEXT PRIMARY KEY,
                route_short_name TEXT,
                route_long_name TEXT,
                route_type INTEGER NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS trips (
                trip_id TEXT PRIMARY KEY,
                route_id TEXT NOT NULL,
                service_id TEXT NOT NULL,
                trip_headsign TEXT,
                direction_id INTEGER DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS stop_times (
                trip_id TEXT NOT NULL,
                stop_id TEXT NOT NULL,
                arrival_time TEXT,
                departure_time TEXT,
                stop_sequence INTEGER NOT NULL,
                arrival_seconds INTEGER,
                departure_seconds INTEGER
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS calendar (
                service_id TEXT PRIMARY KEY,
                monday INTEGER, tuesday INTEGER, wednesday INTEGER,
                thursday INTEGER, friday INTEGER, saturday INTEGER, sunday INTEGER,
                start_date TEXT, end_date TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS calendar_dates (
                service_id TEXT NOT NULL,
                date TEXT NOT NULL,
                exception_type INTEGER NOT NULL
            )
            """,
            // Indices
            "CREATE INDEX IF NOT EXISTS idx_stop_times_stop ON stop_times(stop_id, departure_seconds)",
            "CREATE INDEX IF NOT EXISTS idx_stop_times_trip ON stop_times(trip_id)",
            "CREATE INDEX IF NOT EXISTS idx_trips_route ON trips(route_id)",
            "CREATE INDEX IF NOT EXISTS idx_trips_service ON trips(service_id)",
            "CREATE INDEX IF NOT EXISTS idx_stops_location ON stops(stop_lat, stop_lon)",
            "CREATE INDEX IF NOT EXISTS idx_calendar_dates_date ON calendar_dates(date)",
        ]

        for sql in sqls {
            var errMsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                let msg = errMsg.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(errMsg)
                throw GTFSDBError.queryFailed(msg)
            }
        }
    }

    // MARK: - CSV Import

    private func importCSVFiles(from dir: URL) async throws {
        exec("BEGIN TRANSACTION")

        // Import small files first
        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Importing routes…") }
        try importRoutes(from: dir)

        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Importing trips…") }
        try importTrips(from: dir)

        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Importing stops…") }
        try importStops(from: dir)

        exec("COMMIT")

        // stop_times is the big one — use streaming + batched transactions
        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Importing timetables…", detail: "This is the largest file — please wait") }
        try importStopTimesStreaming(from: dir)

        exec("BEGIN TRANSACTION")
        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Importing calendar…") }
        try importCalendar(from: dir)
        try importCalendarDates(from: dir)

        // Tag stops with route_type based on which routes serve them
        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Finalising database…", detail: "Tagging bus stops") }
        try tagStopsWithRouteType()

        exec("COMMIT")
    }

    private func importStops(from dir: URL) throws {
        let file = dir.appendingPathComponent("stops.txt")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw GTFSDBError.missingFile("stops.txt")
        }

        let sql = "INSERT OR IGNORE INTO stops (stop_id, stop_name, stop_code, stop_lat, stop_lon, location_type, parent_station) VALUES (?,?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed("prepare stops insert")
        }
        defer { sqlite3_finalize(stmt) }

        try iterateCSV(file: file) { headers, values in
            guard let stopId = csvValue(headers, values, "stop_id"),
                  let stopName = csvValue(headers, values, "stop_name"),
                  let latStr = csvValue(headers, values, "stop_lat"),
                  let lonStr = csvValue(headers, values, "stop_lon"),
                  let lat = Double(latStr), let lon = Double(lonStr) else { return }

            let locType = csvValue(headers, values, "location_type").flatMap { Int($0) } ?? 0

            sqlite3_bind_text(stmt, 1, (stopId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (stopName as NSString).utf8String, -1, nil)
            if let code = csvValue(headers, values, "stop_code") {
                sqlite3_bind_text(stmt, 3, (code as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_double(stmt, 4, lat)
            sqlite3_bind_double(stmt, 5, lon)
            sqlite3_bind_int(stmt, 6, Int32(locType))
            if let parent = csvValue(headers, values, "parent_station"), !parent.isEmpty {
                sqlite3_bind_text(stmt, 7, (parent as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 7)
            }

            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    private func importRoutes(from dir: URL) throws {
        let file = dir.appendingPathComponent("routes.txt")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw GTFSDBError.missingFile("routes.txt")
        }

        let sql = "INSERT OR IGNORE INTO routes (route_id, route_short_name, route_long_name, route_type) VALUES (?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed("prepare routes insert")
        }
        defer { sqlite3_finalize(stmt) }

        try iterateCSV(file: file) { headers, values in
            guard let routeId = csvValue(headers, values, "route_id"),
                  let typeStr = csvValue(headers, values, "route_type"),
                  let routeType = Int(typeStr) else { return }

            let shortName = csvValue(headers, values, "route_short_name") ?? ""
            let longName = csvValue(headers, values, "route_long_name") ?? ""

            sqlite3_bind_text(stmt, 1, (routeId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (shortName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (longName as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 4, Int32(routeType))

            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    private func importTrips(from dir: URL) throws {
        let file = dir.appendingPathComponent("trips.txt")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw GTFSDBError.missingFile("trips.txt")
        }

        let sql = "INSERT OR IGNORE INTO trips (trip_id, route_id, service_id, trip_headsign, direction_id) VALUES (?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed("prepare trips insert")
        }
        defer { sqlite3_finalize(stmt) }

        try iterateCSV(file: file) { headers, values in
            guard let tripId = csvValue(headers, values, "trip_id"),
                  let routeId = csvValue(headers, values, "route_id"),
                  let serviceId = csvValue(headers, values, "service_id") else { return }

            let headsign = csvValue(headers, values, "trip_headsign")
            let dirId = csvValue(headers, values, "direction_id").flatMap { Int($0) } ?? 0

            sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (routeId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (serviceId as NSString).utf8String, -1, nil)
            if let h = headsign, !h.isEmpty {
                sqlite3_bind_text(stmt, 4, (h as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int(stmt, 5, Int32(dirId))

            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    /// Streaming import of stop_times.txt — reads line by line to avoid loading
    /// hundreds of MB into memory. Uses batched transactions for performance.
    private func importStopTimesStreaming(from dir: URL) throws {
        let file = dir.appendingPathComponent("stop_times.txt")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw GTFSDBError.missingFile("stop_times.txt")
        }

        guard let fh = FileHandle(forReadingAtPath: file.path) else {
            throw GTFSDBError.missingFile("stop_times.txt (open failed)")
        }
        defer { fh.closeFile() }

        let sql = "INSERT INTO stop_times (trip_id, stop_id, arrival_time, departure_time, stop_sequence, arrival_seconds, departure_seconds) VALUES (?,?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed("prepare stop_times insert")
        }
        defer { sqlite3_finalize(stmt) }

        let batchSize = 50_000
        var rowCount = 0
        var headers: [String]?
        var leftover = ""

        exec("BEGIN TRANSACTION")

        // Read in 1 MB chunks
        let chunkSize = 1_024 * 1_024
        while true {
            let chunk = fh.readData(ofLength: chunkSize)
            let isEOF = chunk.isEmpty

            let text: String
            if isEOF {
                text = leftover
                guard !text.isEmpty else { break }
            } else {
                guard let decoded = String(data: chunk, encoding: .utf8) else { continue }
                text = leftover + decoded
            }

            var lines = text.components(separatedBy: "\n")

            // Keep the last partial line for next iteration (unless EOF)
            if !isEOF {
                leftover = lines.removeLast()
            } else {
                leftover = ""
            }

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                // First line is the header
                if headers == nil {
                    headers = parseCSVLine(trimmed)
                    continue
                }

                let values = parseCSVLine(trimmed)
                guard let hdrs = headers,
                      let tripId = csvValue(hdrs, values, "trip_id"),
                      let stopId = csvValue(hdrs, values, "stop_id"),
                      let seqStr = csvValue(hdrs, values, "stop_sequence"),
                      let seq = Int(seqStr) else { continue }

                let arrTime = csvValue(hdrs, values, "arrival_time") ?? ""
                let depTime = csvValue(hdrs, values, "departure_time") ?? ""

                sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (stopId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (arrTime as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (depTime as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 5, Int32(seq))
                sqlite3_bind_int(stmt, 6, Int32(Self.timeStringToSeconds(arrTime)))
                sqlite3_bind_int(stmt, 7, Int32(Self.timeStringToSeconds(depTime)))

                sqlite3_step(stmt)
                sqlite3_reset(stmt)

                rowCount += 1

                // Batch commit every 50k rows for performance
                if rowCount % batchSize == 0 {
                    exec("COMMIT")
                    exec("BEGIN TRANSACTION")
                    let thousands = rowCount / 1000
                    print("  📊 Imported \(thousands)k stop_times rows…")
                }
            }

            if isEOF { break }
        }

        exec("COMMIT")
        print("  ✅ Imported \(rowCount) stop_times rows total.")
    }

    private func importCalendar(from dir: URL) throws {
        let file = dir.appendingPathComponent("calendar.txt")
        guard FileManager.default.fileExists(atPath: file.path) else { return }

        let sql = "INSERT OR IGNORE INTO calendar (service_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date) VALUES (?,?,?,?,?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed("prepare calendar insert")
        }
        defer { sqlite3_finalize(stmt) }

        try iterateCSV(file: file) { headers, values in
            guard let serviceId = csvValue(headers, values, "service_id") else { return }

            sqlite3_bind_text(stmt, 1, (serviceId as NSString).utf8String, -1, nil)
            for (i, day) in ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"].enumerated() {
                let val = csvValue(headers, values, day).flatMap { Int($0) } ?? 0
                sqlite3_bind_int(stmt, Int32(i + 2), Int32(val))
            }
            sqlite3_bind_text(stmt, 9, ((csvValue(headers, values, "start_date") ?? "") as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 10, ((csvValue(headers, values, "end_date") ?? "") as NSString).utf8String, -1, nil)

            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    private func importCalendarDates(from dir: URL) throws {
        let file = dir.appendingPathComponent("calendar_dates.txt")
        guard FileManager.default.fileExists(atPath: file.path) else { return }

        let sql = "INSERT INTO calendar_dates (service_id, date, exception_type) VALUES (?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed("prepare calendar_dates insert")
        }
        defer { sqlite3_finalize(stmt) }

        try iterateCSV(file: file) { headers, values in
            guard let serviceId = csvValue(headers, values, "service_id"),
                  let date = csvValue(headers, values, "date"),
                  let etStr = csvValue(headers, values, "exception_type"),
                  let et = Int(etStr) else { return }

            sqlite3_bind_text(stmt, 1, (serviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (date as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(et))

            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    /// Tag each stop with route_type based on what routes serve it (via trips → stop_times).
    private func tagStopsWithRouteType() throws {
        // For performance, batch-update: set stops that appear in bus routes to route_type=3
        let sql = """
            UPDATE stops SET route_type = 3
            WHERE stop_id IN (
                SELECT DISTINCT st.stop_id
                FROM stop_times st
                JOIN trips t ON st.trip_id = t.trip_id
                JOIN routes r ON t.route_id = r.route_id
                WHERE r.route_type = 3
            )
        """
        exec(sql)
    }

    // MARK: - Service calendar

    private func todayActiveServiceIds() throws -> [String] {
        let brisbane = TimeZone(identifier: "Australia/Brisbane")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = brisbane
        let now = Date()
        let weekday = cal.component(.weekday, from: now)  // 1=Sun, 2=Mon, ...
        let dateStr = {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd"
            df.timeZone = brisbane
            return df.string(from: now)
        }()

        let dayColumn: String
        switch weekday {
        case 1: dayColumn = "sunday"
        case 2: dayColumn = "monday"
        case 3: dayColumn = "tuesday"
        case 4: dayColumn = "wednesday"
        case 5: dayColumn = "thursday"
        case 6: dayColumn = "friday"
        case 7: dayColumn = "saturday"
        default: dayColumn = "monday"
        }

        // Base services active today
        let baseSql = """
            SELECT service_id FROM calendar
            WHERE \(dayColumn) = 1
              AND start_date <= ?
              AND end_date >= ?
        """

        var activeIds = Set<String>()

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, baseSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dateStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (dateStr as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                activeIds.insert(String(cString: sqlite3_column_text(stmt, 0)))
            }
            sqlite3_finalize(stmt)
        }

        // Apply calendar_dates exceptions
        let exSql = "SELECT service_id, exception_type FROM calendar_dates WHERE date = ?"
        if sqlite3_prepare_v2(db, exSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dateStr as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sid = String(cString: sqlite3_column_text(stmt, 0))
                let et = sqlite3_column_int(stmt, 1)
                if et == 1 { activeIds.insert(sid) }
                else if et == 2 { activeIds.remove(sid) }
            }
            sqlite3_finalize(stmt)
        }

        return Array(activeIds)
    }

    // MARK: - Time parsing

    /// "HH:MM:SS" → total seconds (handles >24h for post-midnight trips).
    static func timeStringToSeconds(_ time: String) -> Int {
        let parts = time.split(separator: ":")
        guard parts.count >= 2 else { return 0 }
        let hours = Int(parts[0]) ?? 0
        let minutes = Int(parts[1]) ?? 0
        let seconds = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Current time as seconds since midnight in Brisbane timezone.
    static func brisbaneMidnightSeconds() -> Int {
        let brisbane = TimeZone(identifier: "Australia/Brisbane")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = brisbane
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let second = cal.component(.second, from: now)
        return hour * 3600 + minute * 60 + second
    }

    // MARK: - ZIP extraction (using Process/unzip CLI on macOS, or NSFileCoordinator)

    private func extractZip(at zipURL: URL, to destination: URL) throws {
        // Use Foundation's built-in ZIP support if available (iOS 16+),
        // otherwise fall back to manual extraction.
        // On iOS, we can use a simple approach with FileManager.
        // For the GTFS ZIP which is a standard ZIP file, we'll use
        // a lightweight approach.

        // Try the unzip approach via spawning — but on iOS we can't use Process.
        // Instead, parse the ZIP manually using Foundation.
        try extractZipManually(at: zipURL, to: destination)
    }

    /// Minimal ZIP extractor — handles the common "stored" and "deflated" entries
    /// in a standard GTFS ZIP file using Apple's built-in Compression framework.
    private func extractZipManually(at zipURL: URL, to destination: URL) throws {
        let data = try Data(contentsOf: zipURL)
        var offset = 0

        while offset + 30 <= data.count {
            // Local file header signature: 0x04034b50
            let sig = data[offset..<offset+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard UInt32(littleEndian: sig) == 0x04034b50 else { break }

            let compressionMethod = data[offset+8..<offset+10].withUnsafeBytes {
                UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))
            }
            let compressedSize = data[offset+18..<offset+22].withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            }
            let uncompressedSize = data[offset+22..<offset+26].withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            }
            let nameLength = data[offset+26..<offset+28].withUnsafeBytes {
                UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))
            }
            let extraLength = data[offset+28..<offset+30].withUnsafeBytes {
                UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))
            }

            let nameStart = offset + 30
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= data.count else { break }
            let fileName = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""

            let dataStart = nameEnd + Int(extraLength)
            let dataEnd = dataStart + Int(compressedSize)
            guard dataEnd <= data.count else { break }

            // Only extract .txt files we need
            let neededFiles = ["stops.txt", "routes.txt", "trips.txt", "stop_times.txt",
                             "calendar.txt", "calendar_dates.txt"]
            let baseName = (fileName as NSString).lastPathComponent

            if neededFiles.contains(baseName) && compressedSize > 0 {
                let compressedData = data[dataStart..<dataEnd]
                let fileData: Data

                if compressionMethod == 0 {
                    // Stored (no compression)
                    fileData = Data(compressedData)
                } else if compressionMethod == 8 {
                    // Deflated — use Compression framework
                    fileData = try decompressDeflate(Data(compressedData), uncompressedSize: Int(uncompressedSize))
                } else {
                    offset = dataEnd
                    continue
                }

                let outputPath = destination.appendingPathComponent(baseName)
                try fileData.write(to: outputPath)
                print("  📄 Extracted \(baseName) (\(fileData.count) bytes)")
            }

            offset = dataEnd
        }
    }

    private func decompressDeflate(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        let bufferSize = uncompressedSize + 1024  // small safety margin
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        let decodedSize = compressed.withUnsafeBytes { srcPtr -> Int in
            guard let baseAddress = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                bufferSize,
                baseAddress,
                compressed.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decodedSize > 0 else {
            throw GTFSDBError.decompressionFailed
        }
        return Data(bytes: destinationBuffer, count: decodedSize)
    }

    // MARK: - CSV parsing

    private func iterateCSV(file: URL, handler: (_ headers: [String], _ values: [String]) -> Void) throws {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            throw GTFSDBError.missingFile(file.lastPathComponent)
        }

        var lines = content.components(separatedBy: .newlines)
        guard let headerLine = lines.first else { return }
        let headers = parseCSVLine(headerLine)
        lines.removeFirst()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let values = parseCSVLine(trimmed)
            handler(headers, values)
        }
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    private func csvValue(_ headers: [String], _ values: [String], _ key: String) -> String? {
        guard let idx = headers.firstIndex(of: key), idx < values.count else { return nil }
        let val = values[idx]
        return val.isEmpty ? nil : val
    }
}

// MARK: - Errors

enum GTFSDBError: LocalizedError {
    case notReady
    case openFailed
    case queryFailed(String)
    case missingFile(String)
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .notReady:             return "GTFS database is not ready."
        case .openFailed:           return "Failed to open GTFS SQLite database."
        case .queryFailed(let msg): return "GTFS query failed: \(msg)"
        case .missingFile(let f):   return "Missing GTFS file: \(f)"
        case .decompressionFailed:  return "Failed to decompress GTFS ZIP entry."
        }
    }
}
