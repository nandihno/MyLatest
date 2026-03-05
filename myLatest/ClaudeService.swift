//
//  ClaudeService.swift
//  myLatest
//
//  Calls the Claude API to analyse health data.
//

import Foundation

// MARK: - Service

enum ClaudeService {

    static func analyseHealthData(
        summary: String,
        age: String,
        apiKey: String
    ) async throws -> String {

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,              forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")

        // Prepend age context if provided.
        var userContent = summary
        if !age.trimmingCharacters(in: .whitespaces).isEmpty {
            userContent = "User age: \(age) years old.\n\n" + summary
        }

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 1024,
            "system": "You are a caring and knowledgeable health advisor. Analyse the health data provided and give personalised, friendly advice. Structure your response with markdown section headers using ## and a relevant emoji for each topic — for example: ## 📊 Summary, ## 💤 Sleep, ## 🏃 Activity, ## ❤️ Heart Rate, ## 💡 Recommendations. Use bullet points (starting with - ) for lists. Use **bold** for key values or important points. Keep each section concise (2–4 points), and use an encouraging, easy-to-understand tone.",
            "messages": [
                ["role": "user", "content": userContent]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if let wrapper = try? JSONDecoder().decode(ClaudeErrorResponse.self, from: data) {
                throw ClaudeAPIError.apiMessage(wrapper.error.message)
            }
            throw ClaudeAPIError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        return decoded.content.first?.text ?? "No analysis available"
    }
}

// MARK: - Decodable helpers

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
