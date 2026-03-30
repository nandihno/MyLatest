//
//  ClaudeService.swift
//  myLatest
//
//  Generic Claude API transport plus domain-specific request builders.
//

import Foundation

// MARK: - AI Provider

enum AIProvider: String {
    case appleIntelligence
    case claude
}

// MARK: - Claude client

private enum ClaudeClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static func send(
        _ payload: ClaudeMessageRequest,
        apiKey: String
    ) async throws -> ClaudeMessageResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if let wrapper = try? JSONDecoder().decode(ClaudeErrorResponse.self, from: data) {
                throw ClaudeAPIError.apiMessage(wrapper.error.message)
            }
            throw ClaudeAPIError.httpStatus(http.statusCode)
        }

        return try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
    }
}

// MARK: - Public service

enum ClaudeService {
    static func analyse(
        spec: ClaudeAnalysisSpec,
        apiKey: String
    ) async throws -> String {
        let request = ClaudeMessageRequest(
            model: spec.model,
            maxTokens: spec.maxTokens,
            system: spec.systemPrompt,
            messages: [.init(role: "user", content: spec.userContent)]
        )

        let response = try await ClaudeClient.send(request, apiKey: apiKey)
        return response.content.compactMap(\.text).first ?? "No analysis available"
    }

    static func analyseHealthData(
        summary: String,
        age: String,
        extraInformation: String,
        apiKey: String
    ) async throws -> String {
        let healthSpec = HealthAnalysisSpecBuilder.make(
            summary: summary,
            age: age,
            extraInformation: extraInformation
        )
        return try await analyse(spec: healthSpec, apiKey: apiKey)
    }

    static func analyseWeather(
        forecastSummary: String,
        apiKey: String
    ) async throws -> String {
        let spec = WeatherAnalysisSpecBuilder.make(forecastSummary: forecastSummary)
        return try await analyse(spec: spec, apiKey: apiKey)
    }
}

// MARK: - Analysis spec

struct ClaudeAnalysisSpec {
    var model: String = "claude-haiku-4-5"
    var maxTokens: Int = 1024
    var systemPrompt: String
    var userContent: String
}

enum WeatherAnalysisSpecBuilder {
    static func make(forecastSummary: String) -> ClaudeAnalysisSpec {
        let now = Date()
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .full
        dateFmt.timeStyle = .short
        let dateTimeStr = dateFmt.string(from: now)

        let userContent = """
        Today's date and time: \(dateTimeStr)

        7-day forecast:
        \(forecastSummary)
        """

        return ClaudeAnalysisSpec(
            systemPrompt: """
            You are a personal weather assistant, giving todays date with the following 7 day forecast.
            Your Task:
            Analyse this weather data and provide a brief, practical summary. Focus on:

            1. TODAY — What to wear, whether to bring an umbrella, UV protection needed, best time for outdoor activity or gym
            2. COMMUTE — Any weather impact on the morning or evening train commute
            3. WEEK AHEAD — Flag any notable days (extreme heat, heavy rain, fire danger)
            4. ACTIVITIES - Flag when is best to hang clothes for washing, when is best to walk outdoors or when not to walk outdoors
            5. ONE SPECIFIC TIP — Something actionable based on the forecast

            RULES:
            - Be concise — max 150 words total
            - Use plain conversational English
            - No bullet points — write in short paragraphs
            - Don't just repeat the data — interpret it
            - If fire danger is Extreme or Catastrophic, always highlight this prominently
            - Temperatures in Celsius
            - Use a ## header for each section (e.g. ## Today, ## Commute, ## Week Ahead, ## Tip)
            """,
            userContent: userContent
        )
    }
}

enum HealthAnalysisSpecBuilder {
    static func make(summary: String, age: String, extraInformation: String) -> ClaudeAnalysisSpec {
        var contentParts: [String] = []
        contentParts.append("Current date and time: \(formattedCurrentDateTime())")

        let trimmedAge = age.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAge.isEmpty {
            contentParts.append("User age: \(trimmedAge) years old.")
        }
        let trimmedExtraInformation = extraInformation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExtraInformation.isEmpty {
            contentParts.append("Extra information: \(trimmedExtraInformation)")
        }
        contentParts.append(summary)

        return ClaudeAnalysisSpec(
            systemPrompt: "You are a caring and knowledgeable health advisor. Analyse the health data provided and give personalised, friendly advice. Structure your response with markdown section headers using ## and a relevant emoji for each topic - for example: ## 📊 Summary, ## 💤 Sleep, ## 🏃 Activity, ## ❤️ Heart Rate, ## 🔥 Energy & Recovery, ## 💡 Recommendations. Use bullet points (starting with - ) for lists. Use **bold** for key values or important points. Keep each section concise (2-4 points), and use an encouraging, easy-to-understand tone. Please consider the user's age and any other relevant factors when providing advice such as the current date and time, as the week starts on a Monday and finishes on a Sunday. Your analysis should be based on how the user is tracking for the week as the user may want your input before the week closes. The data includes a Daily Brief section with today's workouts compared to the same day last week (with percentage change), active energy burned (move ring equivalent), resting heart rate, and VO2 Max 4-week trend — incorporate these into your analysis, commenting on fitness trends, day-over-day comparison, and recovery status.",
            userContent: contentParts.joined(separator: "\n\n")
        )
    }

    static func formattedCurrentDateTime() -> String {
        let now = Date()
        let calendar = Calendar.current
        let day = calendar.component(.day, from: now)

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
        weekdayFormatter.dateFormat = "EEEE"

        let monthYearFormatter = DateFormatter()
        monthYearFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthYearFormatter.dateFormat = "MMMM yyyy"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "h:mm a"

        let ordinalFormatter = NumberFormatter()
        ordinalFormatter.numberStyle = .ordinal
        let ordinalDay = ordinalFormatter.string(from: NSNumber(value: day)) ?? "\(day)"

        return "\(weekdayFormatter.string(from: now)) \(ordinalDay) of \(monthYearFormatter.string(from: now)), \(timeFormatter.string(from: now))"
    }
}

// MARK: - Request/response models

private struct ClaudeMessageRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct ClaudeMessageResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
    let content: [ContentBlock]
}

private struct ClaudeErrorResponse: Decodable {
    struct APIError: Decodable {
        let type: String
        let message: String
    }
    let error: APIError
}

// MARK: - Error type

enum ClaudeAPIError: LocalizedError {
    case apiMessage(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .apiMessage(let msg):    return msg
        case .httpStatus(let code):   return "Request failed with status \(code)"
        }
    }
}
