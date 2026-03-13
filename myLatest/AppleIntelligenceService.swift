//
//  AppleIntelligenceService.swift
//  myLatest
//
//  On-device AI analysis using Apple Foundation Models.
//  Uses the same prompts as ClaudeService for consistent output.
//

import Foundation
import FoundationModels

enum AppleIntelligenceService {

    static func analyseWeather(forecastSummary: String) async throws -> String {
        let spec = WeatherAnalysisSpecBuilder.make(forecastSummary: forecastSummary)
        return try await analyse(spec: spec)
    }

    static func analyseHealthData(
        summary: String,
        age: String,
        extraInformation: String
    ) async throws -> String {
        let spec = HealthAnalysisSpecBuilder.make(
            summary: summary,
            age: age,
            extraInformation: extraInformation
        )
        return try await analyse(spec: spec)
    }

    // MARK: - Private

    private static func analyse(spec: ClaudeAnalysisSpec) async throws -> String {
        let session = LanguageModelSession(instructions: spec.systemPrompt)
        let response = try await session.respond(to: spec.userContent)
        return String(response.content)
    }
}
