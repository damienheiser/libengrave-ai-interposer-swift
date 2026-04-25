import Foundation

/// HTTP client for forwarding requests to backend AI providers.
/// Uses URLSession with async streaming for SSE responses.
public actor BackendClient {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    /// Send a non-streaming request and return the full response
    public func send(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }
        return (data, httpResponse)
    }

    /// Send a streaming request and return an AsyncStream of SSE text chunks
    public func stream(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data?) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (bytes, response) = try await session.bytes(for: request)
        let httpResponse = response as? HTTPURLResponse

        let stream = AsyncThrowingStream<String, Error> { continuation in
            Task {
                do {
                    // Buffer for accumulating partial lines
                    var lineBuffer = ""
                    for try await byte in bytes {
                        let char = Character(UnicodeScalar(byte))
                        lineBuffer.append(char)

                        // Yield complete lines (SSE uses \n delimiters)
                        while let newlineIdx = lineBuffer.firstIndex(of: "\n") {
                            let line = String(lineBuffer[lineBuffer.startIndex...newlineIdx])
                            lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIdx)...])
                            continuation.yield(line)
                        }
                    }
                    // Yield any remaining content
                    if !lineBuffer.isEmpty {
                        continuation.yield(lineBuffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        return (stream, httpResponse)
    }

    /// Build the full URL and headers for a backend request
    public func prepareBackendRequest(
        route: ResolvedRoute,
        canonicalRequest: CanonicalRequest,
        config: EngraveConfig
    ) -> (url: URL, headers: [String: String], body: Data)? {
        let providerConfig = route.providerConfig ?? config.providers[route.provider]

        // Determine base URL and API key
        let baseURL: String
        let apiKey: String?
        let backendType = normalizeBackendType(route.backend)

        switch backendType {
        case "anthropic":
            baseURL = providerConfig?.baseURL ?? "https://api.anthropic.com"
            apiKey = resolveAPIKey(provider: "anthropic", config: providerConfig)
        case "openai":
            baseURL = providerConfig?.baseURL ?? "https://api.openai.com"
            apiKey = resolveAPIKey(provider: "openai", config: providerConfig)
        case "gemini":
            baseURL = providerConfig?.baseURL ?? "https://generativelanguage.googleapis.com"
            apiKey = resolveAPIKey(provider: "gemini", config: providerConfig)
        case "chat_completions":
            baseURL = providerConfig?.baseURL ?? "http://localhost:1234"
            apiKey = resolveAPIKey(provider: "openai_compatible", config: providerConfig)
        default:
            baseURL = providerConfig?.baseURL ?? "http://localhost:1234"
            apiKey = resolveAPIKey(provider: route.provider, config: providerConfig)
        }

        // Build endpoint URL and request body
        let endpointURL: URL
        let requestBody: [String: Any]
        var headers: [String: String] = ["content-type": "application/json"]

        // Add extra headers from provider config
        if let extra = providerConfig?.extraHeaders {
            for (k, v) in extra { headers[k] = v }
        }

        var modifiedRequest = canonicalRequest
        modifiedRequest.model = route.model
        modifiedRequest.stream = true

        switch backendType {
        case "anthropic":
            guard let url = URL(string: "\(baseURL)/v1/messages") else { return nil }
            endpointURL = url
            requestBody = MessageTranslator.canonicalToAnthropicBody(modifiedRequest)
            if let key = apiKey { headers["x-api-key"] = key }
            headers["anthropic-version"] = "2023-06-01"

        case "openai":
            guard let url = URL(string: "\(baseURL)/v1/responses") else { return nil }
            endpointURL = url
            requestBody = MessageTranslator.canonicalToOpenAIBody(modifiedRequest)
            if let key = apiKey { headers["authorization"] = "Bearer \(key)" }

        case "gemini":
            let model = route.model
            var urlStr = "\(baseURL)/v1/models/\(model):streamGenerateContent?alt=sse"
            if let key = apiKey { urlStr += "&key=\(key)" }
            guard let url = URL(string: urlStr) else { return nil }
            endpointURL = url
            requestBody = MessageTranslator.canonicalToGeminiBody(modifiedRequest)

        case "chat_completions":
            guard let url = URL(string: "\(baseURL)/v1/chat/completions") else { return nil }
            endpointURL = url
            requestBody = MessageTranslator.canonicalToChatCompletionsBody(modifiedRequest)
            if let key = apiKey { headers["authorization"] = "Bearer \(key)" }

        default:
            // Default to chat completions
            guard let url = URL(string: "\(baseURL)/v1/chat/completions") else { return nil }
            endpointURL = url
            requestBody = MessageTranslator.canonicalToChatCompletionsBody(modifiedRequest)
            if let key = apiKey { headers["authorization"] = "Bearer \(key)" }
        }

        guard let bodyData = JSON.serialize(requestBody) else { return nil }
        return (endpointURL, headers, bodyData)
    }

    private func normalizeBackendType(_ backend: String) -> String {
        switch backend {
        case "openai_compatible", "local": return "chat_completions"
        case "claude_subscription": return "anthropic"
        case "gemini_subscription", "gemini_cli": return "gemini"
        default: return backend
        }
    }

    private func resolveAPIKey(provider: String, config: EngraveConfig.ProviderConfig?) -> String? {
        // 1. Provider-specific env var from config
        if let envKey = config?.apiKeyEnv, let value = ProcessInfo.processInfo.environment[envKey] {
            return value
        }

        // 2. Interposer-specific env var
        let interposerKey = "INTERPOSER_\(provider.uppercased())_API_KEY"
        if let value = ProcessInfo.processInfo.environment[interposerKey] {
            return value
        }

        // 3. Standard env vars
        switch provider {
        case "anthropic":
            return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        case "openai":
            return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        case "gemini":
            return ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
                ?? ProcessInfo.processInfo.environment["GOOGLE_GEMINI_API_KEY"]
        default:
            return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        }
    }
}

public enum BackendError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from backend"
        case .httpError(let code, let body): return "Backend returned HTTP \(code): \(body)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        }
    }
}
