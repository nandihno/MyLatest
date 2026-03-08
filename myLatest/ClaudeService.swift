//
//  ClaudeService.swift
//  myLatest
//
//  Generic Claude API transport plus domain-specific request builders.
//

import Foundation

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
        apiKey: String
    ) async throws -> String {
        let healthSpec = HealthAnalysisSpecBuilder.make(summary: summary, age: age)
        return try await analyse(spec: healthSpec, apiKey: apiKey)
    }
}

// MARK: - Analysis spec

struct ClaudeAnalysisSpec {
    var model: String = "claude-haiku-4-5"
    var maxTokens: Int = 1024
    var systemPrompt: String
    var userContent: String
}

private enum HealthAnalysisSpecBuilder {
    static func make(summary: String, age: String) -> ClaudeAnalysisSpec {
        var content = summary
        let trimmedAge = age.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAge.isEmpty {
            content = "User age: \(trimmedAge) years old.\n\n" + summary
        }

        return ClaudeAnalysisSpec(
            systemPrompt: "You are a caring and knowledgeable health advisor. Analyse the health data provided and give personalised, friendly advice. Structure your response with markdown section headers using ## and a relevant emoji for each topic - for example: ## 📊 Summary, ## 💤 Sleep, ## 🏃 Activity, ## ❤️ Heart Rate, ## 💡 Recommendations. Use bullet points (starting with - ) for lists. Use **bold** for key values or important points. Keep each section concise (2-4 points), and use an encouraging, easy-to-understand tone.",
            userContent: content
        )
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
