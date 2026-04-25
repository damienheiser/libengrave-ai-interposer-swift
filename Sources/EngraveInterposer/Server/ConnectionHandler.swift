import Foundation
import Network

/// Protocol for governance evaluation — allows decoupling from EngraveGovernance module.
public protocol GovernanceEvaluator: AnyObject, Sendable {
    func evaluateRequest(_ body: [String: Any], provider: String) async -> (allowed: Bool, reason: String?)
    func evaluateToolCall(name: String, input: [String: Any]) async -> (allowed: Bool, reason: String?)
    func evaluateStreamText(_ text: String) async -> (allowed: Bool, reason: String?)
}

/// Handles a single client connection through the full proxy pipeline:
/// parse → route → translate → forward → translate back → respond
public actor ConnectionHandler {
    private let config: EngraveConfig
    private let routeResolver: RouteResolver
    private let backendClient: BackendClient
    private let logger: LogHandler
    private weak var governance: (any GovernanceEvaluator)?

    public init(config: EngraveConfig, backendClient: BackendClient, logger: @escaping LogHandler, governance: (any GovernanceEvaluator)? = nil) {
        self.config = config
        self.routeResolver = RouteResolver(config: config)
        self.backendClient = backendClient
        self.logger = logger
        self.governance = governance
    }

    /// Process an HTTP request and generate a response.
    /// For streaming requests, returns SSE headers and a callback to stream chunks.
    public func handle(request: HTTPRequest) async -> ConnectionResult {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path

        // Handle CORS preflight
        if request.method == "OPTIONS" {
            return .complete(HTTPResponse.cors())
        }

        // Health check
        if path == "/health" {
            return .complete(HTTPResponse.json(["status": "ok", "version": "1.0.0"]))
        }

        // Model list
        if path == "/v1/models" && request.method == "GET" {
            return handleModelList()
        }

        // Determine source provider from path
        let (sourceProvider, pathModel) = RouteResolver.sourceProvider(for: path)
        if sourceProvider == "unknown" {
            return .complete(HTTPResponse.error("Unknown endpoint: \(path)", status: 404))
        }

        // Parse request body
        guard let body = request.jsonBody else {
            return .complete(HTTPResponse.error("Invalid JSON body", status: 400))
        }

        // Parse into canonical IR
        let canonical: CanonicalRequest
        switch sourceProvider {
        case "anthropic":
            canonical = MessageTranslator.parseAnthropicRequest(body)
        case "openai_compatible":
            canonical = MessageTranslator.parseChatCompletionsRequest(body)
        case "openai":
            canonical = MessageTranslator.parseOpenAIRequest(body)
        case "gemini":
            canonical = MessageTranslator.parseGeminiRequest(body, model: pathModel)
        default:
            return .complete(HTTPResponse.error("Unsupported provider: \(sourceProvider)", status: 400))
        }

        logger("[engrave] \(sourceProvider) request: model=\(canonical.model) messages=\(canonical.messages.count) stream=\(canonical.stream)")

        // Governance check
        if let gov = governance {
            let result = await gov.evaluateRequest(body, provider: sourceProvider)
            if !result.allowed {
                let reason = result.reason ?? "Blocked by governance policy"
                logger("[engrave] BLOCKED by governance: \(reason)")
                return .complete(HTTPResponse.error(reason, status: 403))
            }
        }

        // Resolve route
        let route = routeResolver.resolve(sourceProvider: sourceProvider, model: canonical.model)
        logger("[engrave] route: \(sourceProvider)/\(canonical.model) → \(route.backend)/\(route.model)")

        // Prepare backend request
        guard let prepared = await backendClient.prepareBackendRequest(
            route: route, canonicalRequest: canonical, config: config
        ) else {
            return .complete(HTTPResponse.error("Failed to prepare backend request", status: 500))
        }

        // Determine backend response format for parsing
        let backendFormat = normalizeBackendType(route.backend)

        // Forward to backend with streaming
        do {
            let (byteStream, backendResponse) = try await backendClient.stream(
                url: prepared.url, headers: prepared.headers, body: prepared.body
            )

            if let httpResp = backendResponse, httpResp.statusCode >= 400 {
                // Collect error body
                var errorBody = ""
                for try await chunk in byteStream { errorBody += chunk }
                logger("[engrave] backend error: HTTP \(httpResp.statusCode) \(errorBody.prefix(500))")
                return .complete(HTTPResponse.error("Backend error: HTTP \(httpResp.statusCode)", status: httpResp.statusCode))
            }

            // Return streaming response
            return .streaming(StreamingContext(
                sourceProvider: sourceProvider,
                backendFormat: backendFormat,
                byteStream: byteStream,
                requestId: canonical.metadata.requestId,
                model: route.model,
                logger: logger
            ))
        } catch {
            logger("[engrave] backend connection error: \(error.localizedDescription)")
            return .complete(HTTPResponse.error("Backend connection failed: \(error.localizedDescription)", status: 502))
        }
    }

    private func handleModelList() -> ConnectionResult {
        var models: [[String: Any]] = []
        for (providerName, providerConfig) in config.providers {
            for model in providerConfig.models ?? [] {
                models.append([
                    "id": model,
                    "object": "model",
                    "owned_by": providerName,
                ])
            }
        }
        return .complete(HTTPResponse.json(["object": "list", "data": models]))
    }

    private func normalizeBackendType(_ backend: String) -> String {
        switch backend {
        case "openai_compatible", "local": return "chat_completions"
        case "claude_subscription": return "anthropic"
        case "gemini_subscription", "gemini_cli": return "gemini"
        default: return backend
        }
    }
}

// MARK: - Connection Result

public enum ConnectionResult {
    case complete(HTTPResponse)
    case streaming(StreamingContext)
}

// MARK: - Streaming Context

/// Holds everything needed to stream a translated response back to the client
public struct StreamingContext: @unchecked Sendable {
    public let sourceProvider: String
    public let backendFormat: String
    public let byteStream: AsyncThrowingStream<String, Error>
    public let requestId: String
    public let model: String
    public let logger: LogHandler

    /// Process the backend stream and yield translated SSE lines for the client
    public func translateStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let sourceTranslator = StreamTranslator()
                let backendParser = StreamTranslator()
                var sseParser = SSEParser()

                do {
                    for try await chunk in byteStream {
                        let events = sseParser.feed(chunk)
                        for sseEvent in events {
                            if sseEvent.isDone {
                                // Chat completions [DONE] → generate MessageEnd
                                let canonical: [CanonicalStreamEvent] = [.messageEnd]
                                for ce in canonical {
                                    let lines = serializeCanonical(ce, provider: sourceProvider, translator: sourceTranslator, requestId: requestId, model: model)
                                    for line in lines { continuation.yield(line) }
                                }
                                continue
                            }

                            guard let data = sseEvent.data else { continue }

                            // Parse backend SSE into canonical events
                            let canonicalEvents: [CanonicalStreamEvent]
                            switch backendFormat {
                            case "anthropic":
                                canonicalEvents = backendParser.parseAnthropicSSE(eventType: sseEvent.eventType ?? "", data: data)
                            case "openai":
                                canonicalEvents = backendParser.parseOpenAISSE(eventType: sseEvent.eventType ?? "", data: data)
                            case "gemini":
                                canonicalEvents = backendParser.parseGeminiSSE(data: data)
                            case "chat_completions":
                                canonicalEvents = backendParser.parseChatCompletionsSSE(data: data)
                            default:
                                canonicalEvents = backendParser.parseChatCompletionsSSE(data: data)
                            }

                            // Translate canonical events to source format
                            for canonical in canonicalEvents {
                                let lines = serializeCanonical(canonical, provider: sourceProvider, translator: sourceTranslator, requestId: requestId, model: model)
                                for line in lines { continuation.yield(line) }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    logger("[engrave] stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Serialize a canonical event to the source provider's SSE format
private func serializeCanonical(
    _ event: CanonicalStreamEvent,
    provider: String,
    translator: StreamTranslator,
    requestId: String,
    model: String
) -> [String] {
    switch provider {
    case "anthropic":
        return translator.canonicalToAnthropicSSE(event)
    case "openai":
        return translator.canonicalToOpenAISSE(event)
    case "openai_compatible", "chat_completions":
        return translator.canonicalToChatCompletionsSSE(event, id: requestId, model: model)
    case "gemini":
        return translator.canonicalToGeminiSSE(event)
    default:
        return translator.canonicalToChatCompletionsSSE(event, id: requestId, model: model)
    }
}

/// Log handler type
public typealias LogHandler = @Sendable (String) -> Void
