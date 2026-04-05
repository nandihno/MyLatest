//
//  VictorianBusGTFSDatabase.swift
//  myLatest
//
//  Downloads the Transport Victoria statewide GTFS ZIP, extracts the
//  Myki bus slice (folder 4), and imports it into a local SQLite database.
//

import Foundation
import SQLite3
import CoreLocation
import Compression

actor VictorianBusGTFSDatabase {
    static let shared = VictorianBusGTFSDatabase()

    private struct BundledDatabaseManifest: Decodable {
        let dataset: String?
        let sourceUrl: String?
        let modeFolder: String?
        let generatedAt: String?
        let sqliteFile: String?
        let sha256: String?
    }

    private let gtfsZipURL = URL(string: "https://opendata.transport.vic.gov.au/dataset/3f4e292e-7f8a-4ffe-831f-1953be0fe448/resource/fb152201-859f-4882-9206-b768060b50ad/download/gtfs.zip")!
    private let modeFolderName = "4"
    private let nestedArchiveName = "google_transit.zip"
    private let requiredStaticFiles = [
        "stops.txt",
        "routes.txt",
        "trips.txt",
        "stop_times.txt",
        "calendar.txt",
        "calendar_dates.txt"
    ]

    private var db: OpaquePointer?
    private var isImported = false

    private var dbPath: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("gtfs_victorian_bus.sqlite3").path
    }

    private var extractDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("gtfs_victorian_bus_extracted", isDirectory: true)
    }

    private var localZipURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("victoria_gtfs.zip")
    }

    private var cachedManifestURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("gtfs_victorian_bus_manifest.json")
    }

    private func bundledResourceURL(
        named name: String,
        withExtension extensionName: String
    ) -> URL? {
        let fileManager = FileManager.default

        if let nestedURL = Bundle.main.url(
            forResource: name,
            withExtension: extensionName,
            subdirectory: "db/transport/victoria"
        ), fileManager.fileExists(atPath: nestedURL.path) {
            return nestedURL
        }

        if let rootURL = Bundle.main.resourceURL?
            .appendingPathComponent("\(name).\(extensionName)"),
           fileManager.fileExists(atPath: rootURL.path) {
            return rootURL
        }

        return nil
    }

    private var bundledDatabaseURL: URL? {
        bundledResourceURL(named: "gtfs_victorian_bus", withExtension: "sqlite3")
    }

    private var bundledManifestURL: URL? {
        bundledResourceURL(named: "manifest", withExtension: "json")
    }

    func hasBundledDatabaseAsset() -> Bool {
        bundledDatabaseURL != nil
    }

    func isDatabaseReady() -> Bool {
        if isImported && db != nil { return true }

        do {
            try installBundledDatabaseIfNeeded()
        } catch {
            print("⚠️ Failed to install bundled Victorian DB: \(error.localizedDescription)")
        }

        guard FileManager.default.fileExists(atPath: dbPath) else { return false }

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

    func ensureReady() async throws {
        if isImported && db != nil { return }

        try installBundledDatabaseIfNeeded()

        if FileManager.default.fileExists(atPath: dbPath) {
            try openDB()
            let count = queryCount("SELECT COUNT(*) FROM stops")
            if count > 0 {
                isImported = true
                return
            }
        }

        try await downloadAndImport()
    }

    func resetDatabase() throws {
        if let db {
            sqlite3_close(db)
        }
        db = nil
        isImported = false

        let fm = FileManager.default
        let pathsToDelete = [
            dbPath,
            "\(dbPath)-wal",
            "\(dbPath)-shm",
            localZipURL.path
        ]

        for path in pathsToDelete where fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
        if fm.fileExists(atPath: extractDir.path) {
            try fm.removeItem(at: extractDir)
        }
        if fm.fileExists(atPath: cachedManifestURL.path) {
            try fm.removeItem(at: cachedManifestURL)
        }

        Task { @MainActor in
            GTFSDownloadProgress.shared.finish()
        }
    }

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

    func needsRefresh() -> Bool {
        guard FileManager.default.fileExists(atPath: dbPath) else { return true }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
              let modified = attrs[.modificationDate] as? Date else { return true }
        return abs(modified.timeIntervalSinceNow) > 7 * 24 * 3600
    }

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

    func nearbyBusStops(latitude: Double, longitude: Double, radiusMeters: Double = 300) throws -> [(stop: GTFSStop, distanceMeters: Double)] {
        guard let db else { throw GTFSDBError.notReady }

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

    struct ScheduledDeparture {
        let tripId: String
        let stopId: String
        let departureTime: String
        let departureSeconds: Int
        let stopSequence: Int
        let routeId: String
        let tripHeadsign: String?
        let directionId: Int
        let routeShortName: String
        let routeLongName: String
        let stopName: String
    }

    func tripPattern(tripId: String) throws -> [TripPatternStop] {
        guard let db else { throw GTFSDBError.notReady }

        let sql = """
            SELECT st.stop_id, s.stop_name, s.stop_code, s.stop_lat, s.stop_lon,
                   st.arrival_time, st.departure_time,
                   st.arrival_seconds, st.departure_seconds,
                   st.stop_sequence
            FROM stop_times st
            JOIN stops s ON st.stop_id = s.stop_id
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN routes r ON t.route_id = r.route_id
            WHERE st.trip_id = ?
              AND r.route_type = 3
            ORDER BY st.stop_sequence ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)

        var results: [TripPatternStop] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(TripPatternStop(
                stopId: String(cString: sqlite3_column_text(stmt, 0)),
                stopName: String(cString: sqlite3_column_text(stmt, 1)),
                stopCode: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                stopLat: sqlite3_column_double(stmt, 3),
                stopLon: sqlite3_column_double(stmt, 4),
                arrivalTime: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                departureTime: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
                arrivalSeconds: Int(sqlite3_column_int(stmt, 7)),
                departureSeconds: Int(sqlite3_column_int(stmt, 8)),
                stopSequence: Int(sqlite3_column_int(stmt, 9))
            ))
        }

        return results
    }

    struct TripPatternStop {
        let stopId: String
        let stopName: String
        let stopCode: String?
        let stopLat: Double
        let stopLon: Double
        let arrivalTime: String?
        let departureTime: String?
        let arrivalSeconds: Int
        let departureSeconds: Int
        let stopSequence: Int
    }

    private func downloadAndImport() async throws {
        defer {
            Task { @MainActor in
                GTFSDownloadProgress.shared.finish()
            }
        }

        await MainActor.run {
            GTFSDownloadProgress.shared.update(
                stage: "Downloading Victorian bus schedule data…",
                detail: "~213 MB from Transport Victoria"
            )
        }

        let (zipURL, _) = try await URLSession.shared.download(from: gtfsZipURL)

        let localZip = localZipURL
        try? FileManager.default.removeItem(at: localZip)
        try FileManager.default.moveItem(at: zipURL, to: localZip)

        await MainActor.run {
            GTFSDownloadProgress.shared.update(
                stage: "Extracting Victorian bus schedules…",
                detail: "Importing folder 4 (Myki Bus)"
            )
        }

        let extractTo = extractDir
        try? FileManager.default.removeItem(at: extractTo)
        try FileManager.default.createDirectory(at: extractTo, withIntermediateDirectories: true)
        try extractBusModeFiles(from: localZip, to: extractTo)

        await MainActor.run {
            GTFSDownloadProgress.shared.update(
                stage: "Building Victorian bus database…",
                detail: "Importing stops, routes & timetables"
            )
        }

        try? FileManager.default.removeItem(atPath: dbPath)
        try openDB()
        try createTables()
        try await importCSVFiles(from: extractTo)

        isImported = true
        try? FileManager.default.removeItem(at: extractTo)
    }

    private func openDB() throws {
        if db != nil { return }
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw GTFSDBError.openFailed
        }
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("PRAGMA cache_size = -12000")
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

    private func installBundledDatabaseIfNeeded() throws {
        guard let bundledDatabaseURL else { return }

        let fileManager = FileManager.default
        let destinationURL = URL(fileURLWithPath: dbPath)
        let bundledChecksum = try bundledManifest()?.sha256
        let cachedChecksum = try cachedManifest()?.sha256

        let shouldCopyBundledDatabase =
            !fileManager.fileExists(atPath: dbPath) ||
            (bundledChecksum != nil && bundledChecksum != cachedChecksum)

        guard shouldCopyBundledDatabase else { return }

        if let db {
            sqlite3_close(db)
            self.db = nil
        }
        isImported = false

        Task { @MainActor in
            GTFSDownloadProgress.shared.update(
                stage: "Installing bundled Victorian bus database…",
                detail: "Copying the prebuilt SQLite database from the app bundle"
            )
        }
        defer {
            Task { @MainActor in
                GTFSDownloadProgress.shared.finish()
            }
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        for path in [dbPath, "\(dbPath)-wal", "\(dbPath)-shm"] where fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
        if fileManager.fileExists(atPath: cachedManifestURL.path) {
            try fileManager.removeItem(at: cachedManifestURL)
        }

        print("ℹ️ Installing bundled Victorian bus DB from \(bundledDatabaseURL.lastPathComponent)")
        try fileManager.copyItem(at: bundledDatabaseURL, to: destinationURL)

        if let bundledManifestURL {
            try fileManager.copyItem(at: bundledManifestURL, to: cachedManifestURL)
        }
    }

    private func bundledManifest() throws -> BundledDatabaseManifest? {
        guard let bundledManifestURL else { return nil }
        let data = try Data(contentsOf: bundledManifestURL)
        return try JSONDecoder().decode(BundledDatabaseManifest.self, from: data)
    }

    private func cachedManifest() throws -> BundledDatabaseManifest? {
        guard FileManager.default.fileExists(atPath: cachedManifestURL.path) else { return nil }
        let data = try Data(contentsOf: cachedManifestURL)
        return try JSONDecoder().decode(BundledDatabaseManifest.self, from: data)
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
            "CREATE INDEX IF NOT EXISTS idx_vic_stop_times_stop ON stop_times(stop_id, departure_seconds)",
            "CREATE INDEX IF NOT EXISTS idx_vic_stop_times_trip ON stop_times(trip_id)",
            "CREATE INDEX IF NOT EXISTS idx_vic_trips_route ON trips(route_id)",
            "CREATE INDEX IF NOT EXISTS idx_vic_trips_service ON trips(service_id)",
            "CREATE INDEX IF NOT EXISTS idx_vic_stops_location ON stops(stop_lat, stop_lon)",
            "CREATE INDEX IF NOT EXISTS idx_vic_calendar_dates_date ON calendar_dates(date)"
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

    private func importCSVFiles(from dir: URL) async throws {
        exec("BEGIN TRANSACTION")
        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Importing Victorian routes…") }
        try importRoutes(from: dir)

        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Importing Victorian trips…") }
        try importTrips(from: dir)

        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Importing Victorian stops…") }
        try importStops(from: dir)
        exec("COMMIT")

        await MainActor.run {
            GTFSDownloadProgress.shared.update(
                stage: "Importing Victorian timetables…",
                detail: "This may take a little while"
            )
        }
        try importStopTimesStreaming(from: dir)

        exec("BEGIN TRANSACTION")
        await MainActor.run { GTFSDownloadProgress.shared.update(stage: "Importing Victorian service calendar…") }
        try importCalendar(from: dir)
        try importCalendarDates(from: dir)

        await MainActor.run {
            GTFSDownloadProgress.shared.update(
                stage: "Finalising Victorian bus database…",
                detail: "Tagging bus stops"
            )
        }
        try tagStopsWithRouteType()
        exec("COMMIT")
    }

    private func importStops(from dir: URL) throws {
        try importSimpleCSV(
            fileName: "stops.txt",
            sql: "INSERT OR IGNORE INTO stops (stop_id, stop_name, stop_code, stop_lat, stop_lon, location_type, parent_station) VALUES (?,?,?,?,?,?,?)"
        ) { headers, values, stmt in
            guard let stopId = csvValue(headers, values, "stop_id"),
                  let stopName = csvValue(headers, values, "stop_name"),
                  let latStr = csvValue(headers, values, "stop_lat"),
                  let lonStr = csvValue(headers, values, "stop_lon"),
                  let lat = Double(latStr),
                  let lon = Double(lonStr) else { return false }

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
            return true
        }
    }

    private func importRoutes(from dir: URL) throws {
        try importSimpleCSV(
            fileName: "routes.txt",
            sql: "INSERT OR IGNORE INTO routes (route_id, route_short_name, route_long_name, route_type) VALUES (?,?,?,?)"
        ) { headers, values, stmt in
            guard let routeId = csvValue(headers, values, "route_id"),
                  let typeStr = csvValue(headers, values, "route_type"),
                  let routeType = Int(typeStr) else { return false }

            let shortName = csvValue(headers, values, "route_short_name") ?? ""
            let longName = csvValue(headers, values, "route_long_name") ?? ""

            sqlite3_bind_text(stmt, 1, (routeId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (shortName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (longName as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 4, Int32(routeType))
            return true
        }
    }

    private func importTrips(from dir: URL) throws {
        try importSimpleCSV(
            fileName: "trips.txt",
            sql: "INSERT OR IGNORE INTO trips (trip_id, route_id, service_id, trip_headsign, direction_id) VALUES (?,?,?,?,?)"
        ) { headers, values, stmt in
            guard let tripId = csvValue(headers, values, "trip_id"),
                  let routeId = csvValue(headers, values, "route_id"),
                  let serviceId = csvValue(headers, values, "service_id") else { return false }

            let headsign = csvValue(headers, values, "trip_headsign")
            let dirId = csvValue(headers, values, "direction_id").flatMap { Int($0) } ?? 0

            sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (routeId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (serviceId as NSString).utf8String, -1, nil)
            if let headsign, !headsign.isEmpty {
                sqlite3_bind_text(stmt, 4, (headsign as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int(stmt, 5, Int32(dirId))
            return true
        }
    }

    private func importStopTimesStreaming(from dir: URL) throws {
        let file = dir.appendingPathComponent("stop_times.txt")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw GTFSDBError.missingFile("stop_times.txt")
        }

        let sql = "INSERT INTO stop_times (trip_id, stop_id, arrival_time, departure_time, stop_sequence, arrival_seconds, departure_seconds) VALUES (?,?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed("prepare stop_times insert")
        }
        defer { sqlite3_finalize(stmt) }

        let batchSize = 10_000
        var rowCount = 0
        var headerIndices: (tripId: Int, stopId: Int, arrivalTime: Int?, departureTime: Int?, stopSequence: Int)?

        exec("BEGIN TRANSACTION")
        try streamTextLines(file: file) { line in
            if headerIndices == nil {
                let headers = parseCSVLine(line)
                guard let tripIndex = headers.firstIndex(of: "trip_id"),
                      let stopIndex = headers.firstIndex(of: "stop_id"),
                      let sequenceIndex = headers.firstIndex(of: "stop_sequence") else {
                    throw GTFSDBError.queryFailed("stop_times header missing required columns")
                }

                headerIndices = (
                    tripId: tripIndex,
                    stopId: stopIndex,
                    arrivalTime: headers.firstIndex(of: "arrival_time"),
                    departureTime: headers.firstIndex(of: "departure_time"),
                    stopSequence: sequenceIndex
                )
                return
            }

            guard let headerIndices else { return }

            autoreleasepool {
                let values = parseCSVLine(line)

                guard headerIndices.tripId < values.count,
                      headerIndices.stopId < values.count,
                      headerIndices.stopSequence < values.count else { return }

                let tripId = values[headerIndices.tripId]
                let stopId = values[headerIndices.stopId]
                let seqStr = values[headerIndices.stopSequence]

                guard !tripId.isEmpty,
                      !stopId.isEmpty,
                      let seq = Int(seqStr) else { return }

                let arrTime = headerIndices.arrivalTime.flatMap { index in
                    index < values.count ? values[index] : nil
                } ?? ""
                let depTime = headerIndices.departureTime.flatMap { index in
                    index < values.count ? values[index] : nil
                } ?? ""

                sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (stopId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (arrTime as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (depTime as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 5, Int32(seq))
                sqlite3_bind_int(stmt, 6, Int32(Self.timeStringToSeconds(arrTime)))
                sqlite3_bind_int(stmt, 7, Int32(Self.timeStringToSeconds(depTime)))
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                rowCount += 1
                if rowCount % batchSize == 0 {
                    exec("COMMIT")
                    exec("BEGIN TRANSACTION")
                }
            }
        }

        exec("COMMIT")
    }

    private func importCalendar(from dir: URL) throws {
        try importSimpleCSV(
            fileName: "calendar.txt",
            sql: "INSERT OR IGNORE INTO calendar (service_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date) VALUES (?,?,?,?,?,?,?,?,?,?)",
            allowsMissingFile: true
        ) { headers, values, stmt in
            guard let serviceId = csvValue(headers, values, "service_id") else { return false }

            sqlite3_bind_text(stmt, 1, (serviceId as NSString).utf8String, -1, nil)
            for (index, day) in ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"].enumerated() {
                let value = csvValue(headers, values, day).flatMap { Int($0) } ?? 0
                sqlite3_bind_int(stmt, Int32(index + 2), Int32(value))
            }
            sqlite3_bind_text(stmt, 9, ((csvValue(headers, values, "start_date") ?? "") as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 10, ((csvValue(headers, values, "end_date") ?? "") as NSString).utf8String, -1, nil)
            return true
        }
    }

    private func importCalendarDates(from dir: URL) throws {
        try importSimpleCSV(
            fileName: "calendar_dates.txt",
            sql: "INSERT INTO calendar_dates (service_id, date, exception_type) VALUES (?,?,?)",
            allowsMissingFile: true
        ) { headers, values, stmt in
            guard let serviceId = csvValue(headers, values, "service_id"),
                  let date = csvValue(headers, values, "date"),
                  let exceptionTypeString = csvValue(headers, values, "exception_type"),
                  let exceptionType = Int(exceptionTypeString) else { return false }

            sqlite3_bind_text(stmt, 1, (serviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (date as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(exceptionType))
            return true
        }
    }

    private func tagStopsWithRouteType() throws {
        exec("""
            UPDATE stops SET route_type = 3
            WHERE stop_id IN (
                SELECT DISTINCT st.stop_id
                FROM stop_times st
                JOIN trips t ON st.trip_id = t.trip_id
                JOIN routes r ON t.route_id = r.route_id
                WHERE r.route_type = 3
            )
            """)
    }

    private func todayActiveServiceIds() throws -> [String] {
        let melbourne = TimeZone(identifier: "Australia/Melbourne")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = melbourne
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = melbourne
        let dateString = formatter.string(from: now)

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

        var activeIds = Set<String>()
        let baseSQL = """
            SELECT service_id FROM calendar
            WHERE \(dayColumn) = 1
              AND start_date <= ?
              AND end_date >= ?
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, baseSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dateString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (dateString as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                activeIds.insert(String(cString: sqlite3_column_text(stmt, 0)))
            }
            sqlite3_finalize(stmt)
        }

        let exceptionSQL = "SELECT service_id, exception_type FROM calendar_dates WHERE date = ?"
        if sqlite3_prepare_v2(db, exceptionSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dateString as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let serviceId = String(cString: sqlite3_column_text(stmt, 0))
                let exceptionType = sqlite3_column_int(stmt, 1)
                if exceptionType == 1 {
                    activeIds.insert(serviceId)
                } else if exceptionType == 2 {
                    activeIds.remove(serviceId)
                }
            }
            sqlite3_finalize(stmt)
        }

        return Array(activeIds)
    }

    static func timeStringToSeconds(_ time: String) -> Int {
        let parts = time.split(separator: ":")
        guard parts.count >= 2 else { return 0 }
        let hours = Int(parts[0]) ?? 0
        let minutes = Int(parts[1]) ?? 0
        let seconds = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
        return hours * 3600 + minutes * 60 + seconds
    }

    static func melbourneMidnightSeconds() -> Int {
        let melbourne = TimeZone(identifier: "Australia/Melbourne")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = melbourne
        let now = Date()
        return calendar.component(.hour, from: now) * 3600
            + calendar.component(.minute, from: now) * 60
            + calendar.component(.second, from: now)
    }

    private struct ZIPEntryInfo {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: UInt64
    }

    private func extractBusModeFiles(from outerZipURL: URL, to destination: URL) throws {
        let nestedArchiveURL = destination.appendingPathComponent("victorian_bus_inner.zip")

        if let nestedEntry = try zipEntries(in: outerZipURL).first(where: { entry in
            let components = entry.path.split(separator: "/")
            return components.first == Substring(modeFolderName)
                && entry.path.hasSuffix("/\(nestedArchiveName)")
        }) {
            try extractZIPEntry(nestedEntry, fromArchiveAt: outerZipURL, to: nestedArchiveURL)
            defer { try? FileManager.default.removeItem(at: nestedArchiveURL) }
            try extractRequiredFiles(fromArchiveAt: nestedArchiveURL, to: destination)
            return
        }

        let extractedCount = try extractRequiredFiles(fromArchiveAt: outerZipURL, to: destination) { entryPath in
            let components = entryPath.split(separator: "/")
            guard components.count >= 2 else { return false }
            return components.first == Substring(modeFolderName)
        }

        guard extractedCount > 0 else {
            throw GTFSDBError.missingFile("\(modeFolderName)/\(nestedArchiveName)")
        }
    }

    private func extractRequiredFiles(fromArchiveAt archiveURL: URL, to destination: URL) throws {
        let extractedCount = try extractRequiredFiles(fromArchiveAt: archiveURL, to: destination) { _ in true }
        guard extractedCount > 0 else {
            throw GTFSDBError.missingFile("Victorian bus GTFS files")
        }
    }

    private func extractRequiredFiles(fromArchiveAt archiveURL: URL, to destination: URL, pathFilter: (String) -> Bool) throws -> Int {
        var extractedCount = 0

        for entry in try zipEntries(in: archiveURL) {
            let baseName = URL(fileURLWithPath: entry.path).lastPathComponent
            guard requiredStaticFiles.contains(baseName), pathFilter(entry.path) else { continue }
            try extractZIPEntry(entry, fromArchiveAt: archiveURL, to: destination.appendingPathComponent(baseName))
            extractedCount += 1
        }

        return extractedCount
    }

    private func zipEntries(in archiveURL: URL) throws -> [ZIPEntryInfo] {
        let fileHandle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? fileHandle.close() }

        let fileSize = try fileHandle.seekToEnd()
        let maxCommentLength = UInt64(UInt16.max)
        let searchWindow = min(fileSize, maxCommentLength + 22)
        try fileHandle.seek(toOffset: fileSize - searchWindow)
        let tailData = fileHandle.readData(ofLength: Int(searchWindow))

        guard let eocdOffset = findEndOfCentralDirectory(in: tailData) else {
            throw GTFSDBError.queryFailed("Victorian GTFS ZIP end-of-central-directory record was not found")
        }

        let centralDirectorySize = Int(readUInt32LE(from: tailData, offset: eocdOffset + 12))
        let centralDirectoryOffset = UInt64(readUInt32LE(from: tailData, offset: eocdOffset + 16))
        if centralDirectorySize == Int(UInt32.max) || centralDirectoryOffset == UInt64(UInt32.max) {
            throw GTFSDBError.queryFailed("Victorian GTFS ZIP uses an unsupported ZIP64 central directory")
        }

        try fileHandle.seek(toOffset: centralDirectoryOffset)
        let directoryData = fileHandle.readData(ofLength: centralDirectorySize)

        var entries: [ZIPEntryInfo] = []
        var offset = 0

        while offset + 46 <= directoryData.count {
            let signature = readUInt32LE(from: directoryData, offset: offset)
            guard signature == 0x02014b50 else { break }

            let compressionMethod = readUInt16LE(from: directoryData, offset: offset + 10)
            let compressedSize = Int(readUInt32LE(from: directoryData, offset: offset + 20))
            let uncompressedSize = Int(readUInt32LE(from: directoryData, offset: offset + 24))
            let nameLength = Int(readUInt16LE(from: directoryData, offset: offset + 28))
            let extraLength = Int(readUInt16LE(from: directoryData, offset: offset + 30))
            let commentLength = Int(readUInt16LE(from: directoryData, offset: offset + 32))
            let localHeaderOffset = UInt64(readUInt32LE(from: directoryData, offset: offset + 42))

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= directoryData.count else { break }

            let entryPath = String(data: directoryData[nameStart..<nameEnd], encoding: .utf8) ?? ""
            entries.append(ZIPEntryInfo(
                path: entryPath,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))

            offset = nameEnd + extraLength + commentLength
        }

        return entries
    }

    private func findEndOfCentralDirectory(in tailData: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        guard tailData.count >= signature.count else { return nil }

        for offset in stride(from: tailData.count - signature.count, through: 0, by: -1) {
            if tailData[offset] == signature[0],
               tailData[offset + 1] == signature[1],
               tailData[offset + 2] == signature[2],
               tailData[offset + 3] == signature[3] {
                return offset
            }
        }

        return nil
    }

    private func extractZIPEntry(_ entry: ZIPEntryInfo, fromArchiveAt archiveURL: URL, to outputURL: URL) throws {
        let inputHandle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? inputHandle.close() }

        let dataOffset = try zipEntryDataOffset(for: entry, using: inputHandle)
        try inputHandle.seek(toOffset: dataOffset)

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        switch entry.compressionMethod {
        case 0:
            try copyStoredEntry(from: inputHandle, compressedSize: entry.compressedSize, to: outputHandle)
        case 8:
            try inflateEntry(from: inputHandle, compressedSize: entry.compressedSize, to: outputHandle)
        default:
            throw GTFSDBError.queryFailed("Victorian GTFS ZIP uses unsupported compression method \(entry.compressionMethod) for \(entry.path)")
        }
    }

    private func zipEntryDataOffset(for entry: ZIPEntryInfo, using fileHandle: FileHandle) throws -> UInt64 {
        try fileHandle.seek(toOffset: entry.localHeaderOffset)
        let header = fileHandle.readData(ofLength: 30)
        guard header.count == 30, readUInt32LE(from: header, offset: 0) == 0x04034b50 else {
            throw GTFSDBError.queryFailed("Victorian GTFS ZIP local header could not be read")
        }

        let nameLength = UInt64(readUInt16LE(from: header, offset: 26))
        let extraLength = UInt64(readUInt16LE(from: header, offset: 28))
        return entry.localHeaderOffset + 30 + nameLength + extraLength
    }

    private func copyStoredEntry(from inputHandle: FileHandle, compressedSize: Int, to outputHandle: FileHandle) throws {
        var remaining = compressedSize
        let chunkSize = 64 * 1024

        while remaining > 0 {
            let chunk = inputHandle.readData(ofLength: min(chunkSize, remaining))
            guard !chunk.isEmpty else { throw GTFSDBError.decompressionFailed }
            try outputHandle.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }

    private func inflateEntry(from inputHandle: FileHandle, compressedSize: Int, to outputHandle: FileHandle) throws {
        let sourceChunkSize = 64 * 1024
        let destinationChunkSize = 64 * 1024

        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationChunkSize)
        defer { destinationBuffer.deallocate() }

        let initialDestinationPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let initialSourcePointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer {
            initialDestinationPointer.deallocate()
            initialSourcePointer.deallocate()
        }

        var stream = compression_stream(
            dst_ptr: initialDestinationPointer,
            dst_size: 0,
            src_ptr: UnsafePointer(initialSourcePointer),
            src_size: 0,
            state: nil
        )
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw GTFSDBError.decompressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        var remaining = compressedSize
        while remaining > 0 {
            let chunk = inputHandle.readData(ofLength: min(sourceChunkSize, remaining))
            guard !chunk.isEmpty else { throw GTFSDBError.decompressionFailed }
            remaining -= chunk.count

            try chunk.withUnsafeBytes { rawBuffer in
                guard let sourceBase = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }

                stream.src_ptr = sourceBase
                stream.src_size = rawBuffer.count

                while stream.src_size > 0 {
                    stream.dst_ptr = destinationBuffer
                    stream.dst_size = destinationChunkSize
                    status = compression_stream_process(&stream, 0)

                    let produced = destinationChunkSize - stream.dst_size
                    if produced > 0 {
                        try outputHandle.write(contentsOf: UnsafeRawBufferPointer(start: destinationBuffer, count: produced))
                    }

                    if status == COMPRESSION_STATUS_ERROR {
                        throw GTFSDBError.decompressionFailed
                    }
                }
            }
        }

        while true {
            stream.src_ptr = UnsafePointer(initialSourcePointer)
            stream.src_size = 0
            stream.dst_ptr = destinationBuffer
            stream.dst_size = destinationChunkSize
            status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

            let produced = destinationChunkSize - stream.dst_size
            if produced > 0 {
                try outputHandle.write(contentsOf: UnsafeRawBufferPointer(start: destinationBuffer, count: produced))
            }

            if status == COMPRESSION_STATUS_END {
                break
            }
            if status == COMPRESSION_STATUS_ERROR {
                throw GTFSDBError.decompressionFailed
            }
        }
    }

    private func readUInt16LE(from data: Data, offset: Int) -> UInt16 {
        data[offset..<offset + 2].withUnsafeBytes {
            UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))
        }
    }

    private func readUInt32LE(from data: Data, offset: Int) -> UInt32 {
        data[offset..<offset + 4].withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    private func importSimpleCSV(
        fileName: String,
        sql: String,
        allowsMissingFile: Bool = false,
        binder: (_ headers: [String], _ values: [String], _ stmt: OpaquePointer?) -> Bool
    ) throws {
        let file = extractDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            if allowsMissingFile { return }
            throw GTFSDBError.missingFile(fileName)
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed("prepare \(fileName) insert")
        }
        defer { sqlite3_finalize(stmt) }

        try iterateCSV(file: file) { headers, values in
            guard binder(headers, values, stmt) else { return }
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    private func iterateCSV(file: URL, handler: (_ headers: [String], _ values: [String]) -> Void) throws {
        var headers: [String]?

        try streamTextLines(file: file) { line in
            if headers == nil {
                headers = parseCSVLine(line)
                return
            }

            guard let headers else { return }
            handler(headers, parseCSVLine(line))
        }
    }

    private func streamTextLines(file: URL, chunkSize: Int = 64 * 1024, handler: (String) throws -> Void) throws {
        let fileHandle = try FileHandle(forReadingFrom: file)
        defer { try? fileHandle.close() }

        var buffer = Data()

        while true {
            let chunk = try fileHandle.read(upToCount: chunkSize) ?? Data()
            let isEOF = chunk.isEmpty
            if !chunk.isEmpty {
                buffer.append(chunk)
            }

            var lineStart = buffer.startIndex
            var scanIndex = lineStart

            while scanIndex < buffer.endIndex {
                if buffer[scanIndex] == 0x0A {
                    let rawLine = buffer[lineStart..<scanIndex]
                    if let line = decodeLineData(rawLine) {
                        try handler(line)
                    }
                    scanIndex = buffer.index(after: scanIndex)
                    lineStart = scanIndex
                } else {
                    scanIndex = buffer.index(after: scanIndex)
                }
            }

            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }

            if isEOF { break }
        }

        if let finalLine = decodeLineData(buffer[buffer.startIndex..<buffer.endIndex]) {
            try handler(finalLine)
        }
    }

    private func decodeLineData(_ rawLine: Data.SubSequence) -> String? {
        guard !rawLine.isEmpty else { return nil }

        var lineSlice = rawLine
        if lineSlice.last == 0x0D {
            lineSlice = lineSlice.dropLast()
        }
        guard !lineSlice.isEmpty else { return nil }

        return String(decoding: lineSlice, as: UTF8.self)
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                fields.append(normalizeCSVField(current))
                current = ""
            } else {
                current.append(character)
            }
        }

        fields.append(normalizeCSVField(current))
        return fields
    }

    private func normalizeCSVField(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}\u{200b}\u{0000}"))
    }

    private func csvValue(_ headers: [String], _ values: [String], _ key: String) -> String? {
        guard let index = headers.firstIndex(of: key), index < values.count else { return nil }
        let value = values[index]
        return value.isEmpty ? nil : value
    }
}
