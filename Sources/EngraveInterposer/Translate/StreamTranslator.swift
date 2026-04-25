import Foundation

/// Streaming translator state machine.
/// Converts between provider-specific SSE events and CanonicalStreamEvents.
public class StreamTranslator {

    public enum StreamState: Equatable {
        case idle
        case inMessage
        case inBlock(BlockType)
        case done
    }

    public private(set) var state: StreamState = .idle
    public private(set) var blockIndex: UInt32 = 0
    private var toolArgsBuffer = ""
    private var geminiLastTextLen = 0

    public init() {}

    // MARK: - Anthropic SSE → Canonical

    public func parseAnthropicSSE(eventType: String, data: [String: Any]) -> [CanonicalStreamEvent] {
        switch eventType {
        case "message_start":
            state = .inMessage
            let id = JSON.string((JSON.dict(data["message"]))?["id"]) ?? "msg_unknown"
            return [.messageStart(messageId: id)]

        case "content_block_start":
            let index = JSON.uint32(data["index"]) ?? blockIndex
            blockIndex = index
            let block = JSON.dict(data["content_block"]) ?? data
            let blockTypeStr = JSON.string(block["type"]) ?? "text"

            let blockType: BlockType
            var toolUseId: String? = nil
            var toolName: String? = nil
            switch blockTypeStr {
            case "tool_use":
                blockType = .toolUse
                toolArgsBuffer = ""
                toolUseId = JSON.string(block["id"])
                toolName = JSON.string(block["name"])
            case "thinking":
                blockType = .thinking
            default:
                blockType = .text
            }
            state = .inBlock(blockType)
            return [.contentBlockStart(index: index, blockType: blockType, toolUseId: toolUseId, toolName: toolName)]

        case "content_block_delta":
            let index = JSON.uint32(data["index"]) ?? blockIndex
            let delta = JSON.dict(data["delta"]) ?? data
            let deltaType = JSON.string(delta["type"]) ?? ""
            switch deltaType {
            case "text_delta":
                let text = JSON.string(delta["text"]) ?? ""
                return [.textDelta(index: index, text: text)]
            case "input_json_delta":
                let json = JSON.string(delta["partial_json"]) ?? ""
                toolArgsBuffer += json
                return [.toolInputDelta(index: index, partialJson: json)]
            default:
                return []
            }

        case "content_block_stop":
            let index = JSON.uint32(data["index"]) ?? blockIndex
            state = .inMessage
            toolArgsBuffer = ""
            return [.contentBlockEnd(index: index)]

        case "message_delta":
            let stopReasonStr = JSON.string(JSON.dict(data["delta"])?["stop_reason"])
            let stopReason: StopReason
            switch stopReasonStr {
            case "tool_use": stopReason = .toolUse
            case "max_tokens": stopReason = .maxTokens
            default: stopReason = .endTurn
            }
            var usage: Usage? = nil
            if let u = JSON.dict(data["usage"]) {
                usage = Usage(
                    inputTokens: JSON.uint32(u["input_tokens"]) ?? 0,
                    outputTokens: JSON.uint32(u["output_tokens"]) ?? 0
                )
            }
            return [.messageDelta(stopReason: stopReason, usage: usage)]

        case "message_stop":
            state = .done
            return [.messageEnd]

        case "error":
            let message = JSON.string(JSON.dict(data["error"])?["message"]) ?? "Unknown error"
            return [.error(message: message, code: nil)]

        case "ping":
            return []

        default:
            return []
        }
    }

    // MARK: - Canonical → Anthropic SSE

    public func canonicalToAnthropicSSE(_ event: CanonicalStreamEvent) -> [String] {
        switch event {
        case .messageStart(let messageId):
            let data: [String: Any] = [
                "type": "message_start",
                "message": [
                    "id": messageId, "type": "message", "role": "assistant",
                    "content": [] as [Any],
                    "model": "interposed",
                    "usage": ["input_tokens": 0, "output_tokens": 0],
                ] as [String: Any],
            ]
            return [sseEvent("message_start", data)]

        case .contentBlockStart(let index, let blockType, let toolUseId, let toolName):
            let block: [String: Any]
            switch blockType {
            case .text: block = ["type": "text", "text": ""]
            case .toolUse: block = ["type": "tool_use", "id": toolUseId ?? "", "name": toolName ?? "", "input": [:] as [String: Any]]
            case .thinking: block = ["type": "thinking", "thinking": ""]
            }
            let data: [String: Any] = ["type": "content_block_start", "index": index, "content_block": block]
            return [sseEvent("content_block_start", data)]

        case .textDelta(let index, let text):
            let data: [String: Any] = ["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": text]]
            return [sseEvent("content_block_delta", data)]

        case .toolInputDelta(let index, let partialJson):
            let data: [String: Any] = ["type": "content_block_delta", "index": index, "delta": ["type": "input_json_delta", "partial_json": partialJson]]
            return [sseEvent("content_block_delta", data)]

        case .contentBlockEnd(let index):
            return [sseEvent("content_block_stop", ["type": "content_block_stop", "index": index])]

        case .messageDelta(let stopReason, let usage):
            let stopStr: String
            switch stopReason {
            case .endTurn: stopStr = "end_turn"
            case .toolUse: stopStr = "tool_use"
            case .maxTokens: stopStr = "max_tokens"
            case .error: stopStr = "error"
            }
            var data: [String: Any] = ["type": "message_delta", "delta": ["stop_reason": stopStr]]
            if let u = usage { data["usage"] = ["output_tokens": u.outputTokens] }
            return [sseEvent("message_delta", data)]

        case .messageEnd:
            return [sseEvent("message_stop", ["type": "message_stop"])]

        case .error(let message, _):
            return [sseEvent("error", ["type": "error", "error": ["type": "api_error", "message": message]])]
        }
    }

    // MARK: - OpenAI Responses SSE → Canonical

    public func parseOpenAISSE(eventType: String, data: [String: Any]) -> [CanonicalStreamEvent] {
        switch eventType {
        case "response.created":
            state = .inMessage
            let id = JSON.string(JSON.dict(data["response"])?["id"]) ?? "resp_unknown"
            return [.messageStart(messageId: id)]

        case "response.in_progress":
            return []

        case "response.output_item.added":
            let index = JSON.uint32(data["output_index"]) ?? 0
            let itemType = JSON.string(JSON.dict(data["item"])?["type"]) ?? ""
            if itemType == "function_call" {
                state = .inBlock(.toolUse)
                toolArgsBuffer = ""
                let callId = JSON.string(JSON.dict(data["item"])?["call_id"])
                let name = JSON.string(JSON.dict(data["item"])?["name"])
                return [.contentBlockStart(index: index, blockType: .toolUse, toolUseId: callId, toolName: name)]
            }
            return []

        case "response.content_part.added":
            let index = JSON.uint32(data["output_index"]) ?? 0
            state = .inBlock(.text)
            return [.contentBlockStart(index: index, blockType: .text, toolUseId: nil, toolName: nil)]

        case "response.output_text.delta":
            let index = JSON.uint32(data["output_index"]) ?? 0
            let text = JSON.string(data["delta"]) ?? ""
            return [.textDelta(index: index, text: text)]

        case "response.function_call_arguments.delta":
            let index = JSON.uint32(data["output_index"]) ?? 0
            let delta = JSON.string(data["delta"]) ?? ""
            toolArgsBuffer += delta
            return [.toolInputDelta(index: index, partialJson: delta)]

        case "response.function_call_arguments.done", "response.content_part.done":
            let index = JSON.uint32(data["output_index"]) ?? 0
            state = .inMessage
            return [.contentBlockEnd(index: index)]

        case "response.output_item.done":
            return []

        case "response.completed":
            var usage: Usage? = nil
            if let u = JSON.dict(JSON.dict(data["response"])?["usage"]) {
                usage = Usage(
                    inputTokens: JSON.uint32(u["input_tokens"]) ?? 0,
                    outputTokens: JSON.uint32(u["output_tokens"]) ?? 0
                )
            }
            state = .done
            return [.messageDelta(stopReason: .endTurn, usage: usage), .messageEnd]

        case "response.failed":
            let msg = JSON.string(
                JSON.dict(JSON.dict(JSON.dict(data["response"])?["status_details"])?["error"])?["message"]
            ) ?? "Response failed"
            return [.error(message: msg, code: nil)]

        default:
            return []
        }
    }

    // MARK: - Canonical → OpenAI Responses SSE

    public func canonicalToOpenAISSE(_ event: CanonicalStreamEvent) -> [String] {
        switch event {
        case .messageStart(let messageId):
            let created: [String: Any] = [
                "type": "response.created",
                "response": ["id": messageId, "status": "in_progress", "output": [] as [Any]] as [String: Any],
            ]
            let inProgress: [String: Any] = [
                "type": "response.in_progress",
                "response": ["id": messageId, "status": "in_progress"] as [String: Any],
            ]
            return [sseEvent("response.created", created), sseEvent("response.in_progress", inProgress)]

        case .contentBlockStart(let index, let blockType, let toolUseId, let toolName):
            switch blockType {
            case .text:
                let item: [String: Any] = [
                    "type": "response.output_item.added", "output_index": index,
                    "item": ["type": "message", "role": "assistant", "content": [] as [Any]] as [String: Any],
                ]
                let part: [String: Any] = [
                    "type": "response.content_part.added", "output_index": index,
                    "content_index": 0, "part": ["type": "output_text", "text": ""] as [String: Any],
                ]
                return [sseEvent("response.output_item.added", item), sseEvent("response.content_part.added", part)]
            case .toolUse:
                let item: [String: Any] = [
                    "type": "response.output_item.added", "output_index": index,
                    "item": ["type": "function_call", "name": toolName ?? "", "call_id": toolUseId ?? "", "arguments": ""] as [String: Any],
                ]
                return [sseEvent("response.output_item.added", item)]
            default: return []
            }

        case .textDelta(let index, let text):
            let data: [String: Any] = ["type": "response.output_text.delta", "output_index": index, "content_index": 0, "delta": text]
            return [sseEvent("response.output_text.delta", data)]

        case .toolInputDelta(let index, let partialJson):
            let data: [String: Any] = ["type": "response.function_call_arguments.delta", "output_index": index, "delta": partialJson]
            return [sseEvent("response.function_call_arguments.delta", data)]

        case .contentBlockEnd(let index):
            let data: [String: Any] = ["type": "response.output_item.done", "output_index": index, "item": [:] as [String: Any]]
            return [sseEvent("response.output_item.done", data)]

        case .messageDelta: return []

        case .messageEnd:
            let data: [String: Any] = ["type": "response.completed", "response": ["status": "completed"]]
            return [sseEvent("response.completed", data)]

        case .error(let message, let code):
            return [sseEvent("error", ["type": "error", "message": message, "code": code as Any])]
        }
    }

    // MARK: - Gemini SSE → Canonical

    public func parseGeminiSSE(data: [String: Any]) -> [CanonicalStreamEvent] {
        var events: [CanonicalStreamEvent] = []

        // Error check
        if let error = JSON.dict(data["error"]) {
            let message = JSON.string(error["message"]) ?? "Unknown Gemini error"
            return [.error(message: message, code: JSON.int(error["code"]).map { String($0) })]
        }

        guard let candidates = JSON.array(data["candidates"]),
              let candidate = JSON.dict(candidates.first) else { return [] }

        let parts = JSON.array(JSON.dict(candidate["content"])?["parts"])

        if let parts = parts {
            for part in parts {
                guard let part = JSON.dict(part) else { continue }

                // Text part
                if let text = JSON.string(part["text"]), !text.isEmpty {
                    if state != .inBlock(.text) {
                        if case .inBlock(_) = state {
                            events.append(.contentBlockEnd(index: blockIndex))
                            blockIndex += 1
                        }
                        events.append(.contentBlockStart(index: blockIndex, blockType: .text, toolUseId: nil, toolName: nil))
                        state = .inBlock(.text)
                        geminiLastTextLen = 0
                    }
                    // Compute delta for accumulated text
                    let delta: String
                    if text.count > geminiLastTextLen && geminiLastTextLen > 0 {
                        let startIdx = text.index(text.startIndex, offsetBy: geminiLastTextLen)
                        delta = String(text[startIdx...])
                    } else if geminiLastTextLen == 0 {
                        delta = text
                    } else {
                        delta = text
                    }
                    geminiLastTextLen = text.count
                    if !delta.isEmpty {
                        events.append(.textDelta(index: blockIndex, text: delta))
                    }
                }

                // Function call
                if let fc = JSON.dict(part["functionCall"]) {
                    if case .inBlock(_) = state {
                        events.append(.contentBlockEnd(index: blockIndex))
                        blockIndex += 1
                    }
                    let name = JSON.string(fc["name"]) ?? ""
                    let args = fc["args"] ?? [:]
                    let argsStr = JSON.serializeString(args) ?? "{}"
                    let toolId = "gemini_fc_\(blockIndex)"

                    events.append(.contentBlockStart(index: blockIndex, blockType: .toolUse, toolUseId: toolId, toolName: name))
                    events.append(.toolInputDelta(index: blockIndex, partialJson: argsStr))
                    events.append(.contentBlockEnd(index: blockIndex))
                    blockIndex += 1
                    state = .inMessage
                }
            }
        }

        // Finish reason
        if let finishReason = JSON.string(candidate["finishReason"]) {
            if case .inBlock(_) = state {
                events.append(.contentBlockEnd(index: blockIndex))
                state = .inMessage
            }
            var stopReason: StopReason
            switch finishReason {
            case "STOP": stopReason = .endTurn
            case "MAX_TOKENS": stopReason = .maxTokens
            case "SAFETY", "RECITATION", "OTHER": stopReason = .error
            default: stopReason = .endTurn
            }
            // If there were function calls, override to toolUse
            if let parts = parts, parts.contains(where: { JSON.dict($0)?["functionCall"] != nil }) {
                stopReason = .toolUse
            }
            var usage: Usage? = nil
            if let u = JSON.dict(data["usageMetadata"]) {
                usage = Usage(
                    inputTokens: JSON.uint32(u["promptTokenCount"]) ?? 0,
                    outputTokens: JSON.uint32(u["candidatesTokenCount"]) ?? 0
                )
            }
            events.append(.messageDelta(stopReason: stopReason, usage: usage))
        }

        return events
    }

    // MARK: - Canonical → Gemini SSE

    public func canonicalToGeminiSSE(_ event: CanonicalStreamEvent) -> [String] {
        switch event {
        case .messageStart: return []
        case .contentBlockStart: return []
        case .textDelta(_, let text):
            let candidate: [String: Any] = [
                "candidates": [["content": ["parts": [["text": text]], "role": "model"]]] as [Any],
            ]
            return [sseData(candidate)]
        case .toolInputDelta: return []
        case .contentBlockEnd: return []
        case .messageDelta(let stopReason, let usage):
            let finishReason: String
            switch stopReason {
            case .endTurn, .toolUse: finishReason = "STOP"
            case .maxTokens: finishReason = "MAX_TOKENS"
            case .error: finishReason = "OTHER"
            }
            var candidate: [String: Any] = ["candidates": [["finishReason": finishReason]]]
            if let u = usage {
                candidate["usageMetadata"] = ["promptTokenCount": u.inputTokens, "candidatesTokenCount": u.outputTokens]
            }
            return [sseData(candidate)]
        case .messageEnd: return []
        case .error(let message, let code):
            return [sseData(["error": ["message": message, "code": code as Any]])]
        }
    }

    // MARK: - Chat Completions SSE → Canonical

    public func parseChatCompletionsSSE(data: [String: Any]) -> [CanonicalStreamEvent] {
        var events: [CanonicalStreamEvent] = []
        guard let choices = JSON.array(data["choices"]) else { return events }

        for choice in choices {
            guard let choice = JSON.dict(choice) else { continue }
            let delta = JSON.dict(choice["delta"]) ?? [:]

            // Role announcement => MessageStart
            if delta["role"] != nil && state == .idle {
                let id = JSON.string(data["id"]) ?? "chatcmpl_unknown"
                state = .inMessage
                events.append(.messageStart(messageId: id))
            }

            // Text content delta
            if let content = JSON.string(delta["content"]), !content.isEmpty {
                if state != .inBlock(.text) {
                    events.append(.contentBlockStart(index: blockIndex, blockType: .text, toolUseId: nil, toolName: nil))
                    state = .inBlock(.text)
                }
                events.append(.textDelta(index: blockIndex, text: content))
            }

            // Tool calls delta
            if let toolCalls = JSON.array(delta["tool_calls"]) {
                for tc in toolCalls {
                    guard let tc = JSON.dict(tc) else { continue }

                    if tc["id"] != nil {
                        if case .inBlock(_) = state {
                            events.append(.contentBlockEnd(index: blockIndex))
                            blockIndex += 1
                        }
                        let toolId = JSON.string(tc["id"])
                        let toolName = JSON.string(JSON.dict(tc["function"])?["name"])
                        events.append(.contentBlockStart(index: blockIndex, blockType: .toolUse, toolUseId: toolId, toolName: toolName))
                        state = .inBlock(.toolUse)
                        toolArgsBuffer = ""
                    }

                    if let args = JSON.string(JSON.dict(tc["function"])?["arguments"]), !args.isEmpty {
                        let tcIndex = JSON.uint32(tc["index"]) ?? 0
                        toolArgsBuffer += args
                        events.append(.toolInputDelta(index: tcIndex, partialJson: args))
                    }
                }
            }

            // Finish reason
            if let finishReason = JSON.string(choice["finish_reason"]) {
                if case .inBlock(_) = state {
                    events.append(.contentBlockEnd(index: blockIndex))
                    state = .inMessage
                }
                let stopReason: StopReason
                switch finishReason {
                case "stop": stopReason = .endTurn
                case "tool_calls": stopReason = .toolUse
                case "length": stopReason = .maxTokens
                default: stopReason = .endTurn
                }
                var usage: Usage? = nil
                if let u = JSON.dict(data["usage"]) {
                    usage = Usage(
                        inputTokens: JSON.uint32(u["prompt_tokens"]) ?? 0,
                        outputTokens: JSON.uint32(u["completion_tokens"]) ?? 0
                    )
                }
                events.append(.messageDelta(stopReason: stopReason, usage: usage))
                events.append(.messageEnd)
                state = .done
            }
        }
        return events
    }

    // MARK: - Canonical → Chat Completions SSE

    public func canonicalToChatCompletionsSSE(_ event: CanonicalStreamEvent, id: String, model: String) -> [String] {
        switch event {
        case .messageStart:
            return [chatChunk(id: id, model: model, delta: ["role": "assistant", "content": ""], finishReason: nil)]

        case .textDelta(_, let text):
            return [chatChunk(id: id, model: model, delta: ["content": text], finishReason: nil)]

        case .contentBlockStart(let index, let blockType, let toolUseId, let toolName):
            if blockType == .toolUse {
                let delta: [String: Any] = [
                    "tool_calls": [["index": index, "id": toolUseId as Any, "type": "function", "function": ["name": toolName as Any, "arguments": ""]]] as [Any],
                ]
                return [chatChunk(id: id, model: model, delta: delta, finishReason: nil)]
            }
            return []

        case .toolInputDelta(let index, let partialJson):
            let delta: [String: Any] = [
                "tool_calls": [["index": index, "function": ["arguments": partialJson]]] as [Any],
            ]
            return [chatChunk(id: id, model: model, delta: delta, finishReason: nil)]

        case .contentBlockEnd: return []

        case .messageDelta(let stopReason, _):
            let finish: String
            switch stopReason {
            case .endTurn: finish = "stop"
            case .toolUse: finish = "tool_calls"
            case .maxTokens: finish = "length"
            case .error: finish = "stop"
            }
            return [chatChunk(id: id, model: model, delta: [:], finishReason: finish)]

        case .messageEnd:
            return ["data: [DONE]\n\n"]

        case .error(let message, _):
            return ["data: {\"error\":{\"message\":\"\(message)\"}}\n\n"]
        }
    }

    // MARK: - Helpers

    private func sseEvent(_ eventType: String, _ data: [String: Any]) -> String {
        let json = JSON.serializeString(data) ?? "{}"
        return "event: \(eventType)\ndata: \(json)\n\n"
    }

    private func sseData(_ data: [String: Any]) -> String {
        let json = JSON.serializeString(data) ?? "{}"
        return "data: \(json)\n\n"
    }

    private func chatChunk(id: String, model: String, delta: [String: Any], finishReason: String?) -> String {
        let chunk: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "model": model,
            "choices": [["index": 0, "delta": delta, "finish_reason": finishReason as Any]] as [Any],
        ]
        _ = chunk // suppress unused
        let json = JSON.serializeString(chunk) ?? "{}"
        return "data: \(json)\n\n"
    }
}
