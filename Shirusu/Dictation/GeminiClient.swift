import Foundation

/// Minimal Gemini GenerateContent client for one isolated rewrite.
///
/// It deliberately has no conversation state: adjacent dictations must never
/// become context for one another. The API key is sent in an HTTP header rather
/// than a query string, so it cannot be accidentally retained in a URL log.
actor GeminiClient {
    enum ClientError: LocalizedError {
        case invalidModel
        case server(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidModel:
                return "The selected Gemini model name is not valid."
            case .server(let message):
                return message
            case .emptyResponse:
                return "Gemini returned no text."
            }
        }
    }

    func generate(
        apiKey: String,
        model: String,
        instructions: String,
        prompt: String,
        maximumOutputTokens: Int
    ) async throws -> String {
        guard !model.isEmpty,
            model.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else { throw ClientError.invalidModel }

        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
        else { throw ClientError.invalidModel }

        let body = Request(
            systemInstruction: Content(parts: [.init(text: instructions)]),
            contents: [.init(role: "user", parts: [.init(text: prompt)])],
            generationConfig: .init(
                // Gemini 3 models recommend their default temperature. The
                // deterministic behaviour is imposed by the instructions and
                // response guard instead of forcing temperature to zero.
                maxOutputTokens: max(1, maximumOutputTokens)
            )
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.server("Gemini did not return an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
                ?? "Gemini returned HTTP \(http.statusCode)."
            throw ClientError.server(message)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.candidates?
            .first?
            .content?
            .parts
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw ClientError.emptyResponse }
        return text
    }
}

private extension GeminiClient {
    struct Request: Encodable {
        let systemInstruction: Content
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    struct GenerationConfig: Encodable {
        let maxOutputTokens: Int
    }

    struct Content: Codable {
        let role: String?
        let parts: [Part]

        init(role: String? = nil, parts: [Part]) {
            self.role = role
            self.parts = parts
        }
    }

    struct Part: Codable {
        let text: String?

        init(text: String) { self.text = text }
    }

    struct Response: Decodable {
        let candidates: [Candidate]?
    }

    struct Candidate: Decodable {
        let content: Content?
    }

    struct ErrorResponse: Decodable {
        let error: APIError
    }

    struct APIError: Decodable {
        let message: String
    }
}
