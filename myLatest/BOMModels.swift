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

// MARK: - Forecast location lookup

struct BOMLocationSearchResponse: Decodable {
    let data: [BOMLocationSearchItem]
}

struct BOMLocationSearchItem: Decodable {
    let geohash: String
    let name: String
}

// MARK: - Daily forecast

struct BOMDailyForecastResponse: Decodable {
    let data: [BOMDailyForecastDay]
}

struct BOMDailyForecastDay: Decodable {
    let rain: BOMForecastRain?
    let uv: BOMForecastUV?
    let date: String
    let tempMax: Int?
    let tempMin: Int?
    let extendedText: String?
    let shortText: String?
    let fireDanger: String?
    let now: BOMForecastNow?

    enum CodingKeys: String, CodingKey {
        case rain
        case uv
        case date
        case tempMax = "temp_max"
        case tempMin = "temp_min"
        case extendedText = "extended_text"
        case shortText = "short_text"
        case fireDanger = "fire_danger"
        case now
    }
}

struct BOMForecastRain: Decodable {
    let amount: BOMForecastRainAmount?
    let chance: Int?
    let chanceOfNoRainCategory: String?

    enum CodingKeys: String, CodingKey {
        case amount
        case chance
        case chanceOfNoRainCategory = "chance_of_no_rain_category"
    }
}

struct BOMForecastRainAmount: Decodable {
    let min: Int?
    let max: Int?
}

struct BOMForecastUV: Decodable {
    let category: String?
}

struct BOMForecastNow: Decodable {
    let isNight: Bool?
    let nowLabel: String?
    let laterLabel: String?
    let tempNow: Int?
    let tempLater: Int?

    enum CodingKeys: String, CodingKey {
        case isNight = "is_night"
        case nowLabel = "now_label"
        case laterLabel = "later_label"
        case tempNow = "temp_now"
        case tempLater = "temp_later"
    }
}
