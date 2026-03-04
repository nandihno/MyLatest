//
//  BOMModels.swift
//  myLatest
//
//  Decodable structs that mirror the Bureau of Meteorology JSON structure.
//

import Foundation

// MARK: - Top-level

struct BOMResponse: Decodable {
    let observations: BOMObservations
}

struct BOMObservations: Decodable {
    let header: [BOMHeader]
    let data: [BOMDataPoint]
}

// MARK: - Header

struct BOMHeader: Decodable {
    let name: String?   // station name, e.g. "Laverton"
    let state: String?  // e.g. "Victoria"
}

// MARK: - Data point  (one observation per 30-min interval)

struct BOMDataPoint: Decodable {
    let sortOrder: Int          // 0 = most recent
    let localDateTime: String   // e.g. "04/11:30am"
    let apparentT: Double?      // apparent (feels-like) temperature °C
    let airTemp: Double?        // actual air temperature °C
    let relHum: Int?            // relative humidity %
    let cloud: String?          // "Cloudy", "Mostly Cloudy", "" / "-" means clear
    let windDir: String?        // compass bearing e.g. "SW"
    let windSpdKmh: Int?        // wind speed km/h

    enum CodingKeys: String, CodingKey {
        case sortOrder    = "sort_order"
        case localDateTime = "local_date_time"
        case apparentT    = "apparent_t"
        case airTemp      = "air_temp"
        case relHum       = "rel_hum"
        case cloud
        case windDir      = "wind_dir"
        case windSpdKmh   = "wind_spd_kmh"
    }
}
