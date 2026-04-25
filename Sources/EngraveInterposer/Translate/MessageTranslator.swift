import Foundation

/// Translates request/response bodies between all 4 API formats and the Canonical IR.
public enum MessageTranslator {

    // MARK: - Anthropic Messages API

    public static func parseAnthropicRequest(_ body: [String: Any]) -> CanonicalRequest {
        let model = JSON.string(body["model"]) ?? "unknown"

        // System: can be string or array of {type: "text", text: "..."}
        var system: String? = nil
        if let s = JSON.string(body["system"]) {
            system = s
        } else if let arr = JSON.array(body["system"]) {
            let parts = arr.compactMap { item -> String? in
                guard let d = JSON.dict(item) else { return nil }
                return JSON.string(d["text"])
            }
            if !parts.isEmpty { system = parts.joined(separator: "\n") }
        }

        let messages = (JSON.array(body["messages"]) ?? []).compactMap { parseAnthropicMessage(JSON.dict($0)) }
        let tools = (JSON.array(body["tools"]) ?? []).compactMap { ToolTranslator.anthropicToCanonical(JSON.dict($0) ?? [:]) }
        let stream = JSON.bool(body["stream"]) ?? false
        let maxTokens = JSON.uint32(body["max_tokens"])
        let temperature = JSON.float(body["temperature"])

        return CanonicalRequest(
            system: system, messages: messages, tools: tools,
            model: model, maxTokens: maxTokens, temperature: temperature,
            stream: stream,
            metadata: RequestMetadata(sourceProvider: .anthropic, targetProvider: .anthropic)
        )
    }

    private static func parseAnthropicMessage(_ msg: [String: Any]?) -> CanonicalMessage? {
        guard let msg = msg else { return nil }
        guard let roleStr = JSON.string(msg["role"]) else { return nil }
        let role: Role
        switch roleStr {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }

        var content: [ContentBlock] = []
        if let text = JSON.string(msg["content"]) {
            content = [.text(TextBlock(text: text))]
        } else if let blocks = JSON.array(msg["content"]) {
            content = blocks.compactMap { parseAnthropicContentBlock(JSON.dict($0)) }
        }
        return CanonicalMessage(role: role, content: content)
    }

    private static func parseAnthropicContentBlock(_ block: [String: Any]?) -> ContentBlock? {
        guard let block = block, let type = JSON.string(block["type"]) else { return nil }
        switch type {
        case "text":
            guard let text = JSON.string(block["text"]) else { return nil }
            return .text(TextBlock(text: text))
        case "tool_use":
            guard let id = JSON.string(block["id"]),
                  let name = JSON.string(block["name"]) else { return nil }
            let input = JSON.dict(block["input"]) ?? [:]
            return .toolUse(ToolUseBlock(id: id, name: name, input: input))
        case "tool_result":
            guard let toolUseId = JSON.string(block["tool_use_id"]) else { return nil }
            let content = JSON.string(block["content"]) ?? ""
            let isError = JSON.bool(block["is_error"]) ?? false
            return .toolResult(ToolResultBlock(toolUseId: toolUseId, content: content, isError: isError))
        case "thinking":
            guard let thinking = JSON.string(block["thinking"]) else { return nil }
            let sig = JSON.string(block["signature"])
            return .thinking(ThinkingBlock(thinking: thinking, signature: sig))
        default:
            return nil
        }
    }

    public static func canonicalToAnthropicBody(_ req: CanonicalRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": req.model,
            "stream": req.stream,
            "max_tokens": req.maxTokens.map { Int($0) } ?? 16384,
        ]
        if let temp = req.temperature { body["temperature"] = temp }
        if let system = req.system {
            body["system"] = [["type": "text", "text": system]]
        }
        body["messages"] = req.messages.map { canonicalMessageToAnthropic($0) }
        if !req.tools.isEmpty {
            body["tools"] = req.tools.map { ToolTranslator.canonicalToAnthropic($0) }
        }
        return body
    }

    private static func canonicalMessageToAnthropic(_ msg: CanonicalMessage) -> [String: Any] {
        let role = msg.role == .user ? "user" : "assistant"
        let content: [[String: Any]] = msg.content.map { block in
            switch block {
            case .text(let t):
                return ["type": "text", "text": t.text]
            case .toolUse(let t):
                return ["type": "tool_use", "id": t.id, "name": t.name, "input": t.input]
            case .toolResult(let t):
                return ["type": "tool_result", "tool_use_id": t.toolUseId, "content": t.content, "is_error": t.isError]
            case .thinking(let t):
                var v: [String: Any] = ["type": "thinking", "thinking": t.thinking]
                if let sig = t.signature { v["signature"] = sig }
                return v
            case .image(let img):
                return ["type": "image", "source": ["type": "base64", "media_type": img.mediaType, "data": img.data]]
            }
        }
        return ["role": role, "content": content]
    }

    // MARK: - OpenAI Chat Completions

    public static func parseChatCompletionsRequest(_ body: [String: Any]) -> CanonicalRequest {
        let model = JSON.string(body["model"]) ?? "unknown"
        let stream = JSON.bool(body["stream"]) ?? false
        let maxTokens = JSON.uint32(body["max_tokens"]) ?? JSON.uint32(body["max_completion_tokens"])
        let temperature = JSON.float(body["temperature"])

        var system: String? = nil
        var messages: [CanonicalMessage] = []

        for msg in (JSON.array(body["messages"]) ?? []) {
            guard let m = JSON.dict(msg), let roleStr = JSON.string(m["role"]) else { continue }
            switch roleStr {
            case "system", "developer":
                system = extractChatCompletionsContent(m)
            case "user":
                let text = extractChatCompletionsContent(m)
                let content: [ContentBlock] = text.isEmpty ? [] : [.text(TextBlock(text: text))]
                messages.append(CanonicalMessage(role: .user, content: content))
            case "assistant":
                var content: [ContentBlock] = []
                let text = extractChatCompletionsContent(m)
                if !text.isEmpty { content.append(.text(TextBlock(text: text))) }
                if let toolCalls = JSON.array(m["tool_calls"]) {
                    for tc in toolCalls {
                        guard let tc = JSON.dict(tc) else { continue }
                        let id = JSON.string(tc["id"]) ?? ""
                        let funcDef = JSON.dict(tc["function"])
                        let name = JSON.string(funcDef?["name"]) ?? ""
                        let argsStr = JSON.string(funcDef?["arguments"]) ?? "{}"
                        let input = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]
                        content.append(.toolUse(ToolUseBlock(id: id, name: name, input: input)))
                    }
                }
                messages.append(CanonicalMessage(role: .assistant, content: content))
            case "tool":
                let toolResult = ToolResultBlock(
                    toolUseId: JSON.string(m["tool_call_id"]) ?? "",
                    content: extractChatCompletionsContent(m)
                )
                if let last = messages.last, last.role == .user {
                    messages[messages.count - 1].content.append(.toolResult(toolResult))
                } else {
                    messages.append(CanonicalMessage(role: .user, content: [.toolResult(toolResult)]))
                }
            default:
                break
            }
        }

        let tools = (JSON.array(body["tools"]) ?? []).compactMap { ToolTranslator.chatCompletionsToCanonical(JSON.dict($0) ?? [:]) }

        return CanonicalRequest(
            system: system, messages: messages, tools: tools,
            model: model, maxTokens: maxTokens, temperature: temperature,
            stream: stream,
            metadata: RequestMetadata(sourceProvider: .openAICompatible, targetProvider: .openAICompatible)
        )
    }

    private static func extractChatCompletionsContent(_ msg: [String: Any]) -> String {
        if let text = JSON.string(msg["content"]) { return text }
        if let parts = JSON.array(msg["content"]) {
            return parts.compactMap { part -> String? in
                guard let p = JSON.dict(part) else { return nil }
                let ptype = JSON.string(p["type"]) ?? "text"
                return ptype == "text" ? JSON.string(p["text"]) : nil
            }.joined()
        }
        return ""
    }

    public static func canonicalToChatCompletionsBody(_ req: CanonicalRequest) -> [String: Any] {
        var body: [String: Any] = ["model": req.model, "stream": req.stream]
        if let maxTokens = req.maxTokens { body["max_tokens"] = Int(maxTokens) }
        if let temp = req.temperature { body["temperature"] = temp }

        var msgs: [[String: Any]] = []
        if let system = req.system {
            msgs.append(["role": "system", "content": system])
        }

        for msg in req.messages {
            let role = msg.role == .user ? "user" : "assistant"
            var textParts: [String] = []
            var toolCalls: [[String: Any]] = []
            var toolResults: [[String: Any]] = []

            for block in msg.content {
                switch block {
                case .text(let t): textParts.append(t.text)
                case .toolUse(let tu):
                    let argsStr = JSON.serializeString(tu.input) ?? "{}"
                    toolCalls.append([
                        "id": tu.id, "type": "function",
                        "function": ["name": tu.name, "arguments": argsStr],
                    ])
                case .toolResult(let tr):
                    toolResults.append(["role": "tool", "tool_call_id": tr.toolUseId, "content": tr.content])
                default: break
                }
            }

            if !textParts.isEmpty || !toolCalls.isEmpty || toolResults.isEmpty {
                var message: [String: Any] = ["role": role]
                message["content"] = textParts.isEmpty ? NSNull() : textParts.joined()
                if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
                msgs.append(message)
            }
            msgs.append(contentsOf: toolResults)
        }
        body["messages"] = msgs

        if !req.tools.isEmpty {
            body["tools"] = req.tools.map { ToolTranslator.canonicalToChatCompletions($0) }
        }
        return body
    }

    // MARK: - OpenAI Responses API

    public static func parseOpenAIRequest(_ body: [String: Any]) -> CanonicalRequest {
        let model = JSON.string(body["model"]) ?? "unknown"
        let system = JSON.string(body["instructions"])
        let stream = JSON.bool(body["stream"]) ?? false
        let maxTokens = JSON.uint32(body["max_output_tokens"])
        let temperature = JSON.float(body["temperature"])

        let messages = parseOpenAIInputItems(JSON.array(body["input"]) ?? [])
        let tools = (JSON.array(body["tools"]) ?? []).compactMap { ToolTranslator.openAIToCanonical(JSON.dict($0) ?? [:]) }

        return CanonicalRequest(
            system: system, messages: messages, tools: tools,
            model: model, maxTokens: maxTokens, temperature: temperature,
            stream: stream,
            metadata: RequestMetadata(sourceProvider: .openAI, targetProvider: .openAI)
        )
    }

    private static func parseOpenAIInputItems(_ items: [Any]) -> [CanonicalMessage] {
        var messages: [CanonicalMessage] = []
        for item in items {
            guard let item = JSON.dict(item) else { continue }
            let itemType = JSON.string(item["type"]) ?? ""
            switch itemType {
            case "message":
                guard let roleStr = JSON.string(item["role"]) else { continue }
                let role: Role = roleStr == "assistant" ? .assistant : .user
                var content: [ContentBlock] = []
                if let text = JSON.string(item["content"]) {
                    content = [.text(TextBlock(text: text))]
                } else if let parts = JSON.array(item["content"]) {
                    for part in parts {
                        guard let p = JSON.dict(part), let ptype = JSON.string(p["type"]) else { continue }
                        switch ptype {
                        case "output_text", "input_text":
                            if let text = JSON.string(p["text"]) {
                                content.append(.text(TextBlock(text: text)))
                            }
                        case "function_call":
                            let callId = JSON.string(p["call_id"]) ?? ""
                            let name = JSON.string(p["name"]) ?? ""
                            let argsStr = JSON.string(p["arguments"]) ?? "{}"
                            let input = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]
                            content.append(.toolUse(ToolUseBlock(id: callId, name: name, input: input)))
                        default: break
                        }
                    }
                }
                messages.append(CanonicalMessage(role: role, content: content))
            case "function_call_output":
                let toolResult = ToolResultBlock(
                    toolUseId: JSON.string(item["call_id"]) ?? "",
                    content: JSON.string(item["output"]) ?? ""
                )
                if let last = messages.last, last.role == .user {
                    messages[messages.count - 1].content.append(.toolResult(toolResult))
                } else {
                    messages.append(CanonicalMessage(role: .user, content: [.toolResult(toolResult)]))
                }
            default: break
            }
        }
        return messages
    }

    public static func canonicalToOpenAIBody(_ req: CanonicalRequest) -> [String: Any] {
        var body: [String: Any] = ["model": req.model, "stream": req.stream]
        if let instructions = req.system { body["instructions"] = instructions }
        if let maxTokens = req.maxTokens { body["max_output_tokens"] = Int(maxTokens) }
        if let temp = req.temperature { body["temperature"] = temp }

        var items: [Any] = []
        for msg in req.messages {
            let role = msg.role == .user ? "user" : "assistant"
            var contentParts: [[String: Any]] = []
            var toolResults: [[String: Any]] = []

            for block in msg.content {
                switch block {
                case .toolResult(let tr):
                    toolResults.append(["type": "function_call_output", "call_id": tr.toolUseId, "output": tr.content])
                case .text(let t):
                    let textType = msg.role == .user ? "input_text" : "output_text"
                    contentParts.append(["type": textType, "text": t.text])
                case .toolUse(let tu):
                    let argsStr = JSON.serializeString(tu.input) ?? "{}"
                    contentParts.append(["type": "function_call", "call_id": tu.id, "name": tu.name, "arguments": argsStr])
                default: break
                }
            }

            if !contentParts.isEmpty {
                items.append(["type": "message", "role": role, "content": contentParts] as [String: Any])
            } else if toolResults.isEmpty {
                items.append(["type": "message", "role": role, "content": ""] as [String: Any])
            }
            items.append(contentsOf: toolResults)
        }
        body["input"] = items

        if !req.tools.isEmpty {
            body["tools"] = req.tools.map { ToolTranslator.canonicalToOpenAI($0) }
        }
        return body
    }

    // MARK: - Gemini

    public static func parseGeminiRequest(_ body: [String: Any], model: String? = nil) -> CanonicalRequest {
        let modelName = model ?? JSON.string(body["model"]) ?? "gemini-pro"

        // System instruction
        var system: String? = nil
        if let si = JSON.dict(body["system_instruction"]),
           let parts = JSON.array(si["parts"]) {
            let texts = parts.compactMap { p -> String? in JSON.string(JSON.dict(p)?["text"]) }
            if !texts.isEmpty { system = texts.joined(separator: "\n") }
        }

        // Contents -> messages
        let messages = (JSON.array(body["contents"]) ?? []).compactMap { parseGeminiContent(JSON.dict($0)) }

        // Tools: wrapped in tools[].functionDeclarations[]
        var tools: [CanonicalToolDef] = []
        if let toolGroups = JSON.array(body["tools"]) {
            for group in toolGroups {
                guard let g = JSON.dict(group), let decls = JSON.array(g["functionDeclarations"]) else { continue }
                tools.append(contentsOf: decls.compactMap { ToolTranslator.geminiToCanonical(JSON.dict($0) ?? [:]) })
            }
        }

        // Generation config
        let genConfig = JSON.dict(body["generationConfig"])
        let maxTokens = JSON.uint32(genConfig?["maxOutputTokens"])
        let temperature = JSON.float(genConfig?["temperature"])

        return CanonicalRequest(
            system: system, messages: messages, tools: tools,
            model: modelName, maxTokens: maxTokens, temperature: temperature,
            stream: true,
            metadata: RequestMetadata(sourceProvider: .gemini, targetProvider: .gemini)
        )
    }

    private static func parseGeminiContent(_ msg: [String: Any]?) -> CanonicalMessage? {
        guard let msg = msg, let roleStr = JSON.string(msg["role"]) else { return nil }
        let role: Role
        switch roleStr {
        case "user": role = .user
        case "model": role = .assistant
        default: return nil
        }
        guard let parts = JSON.array(msg["parts"]) else { return nil }
        let content = parts.compactMap { parseGeminiPart(JSON.dict($0)) }
        return CanonicalMessage(role: role, content: content)
    }

    private static func parseGeminiPart(_ part: [String: Any]?) -> ContentBlock? {
        guard let part = part else { return nil }
        if let text = JSON.string(part["text"]) {
            return .text(TextBlock(text: text))
        }
        if let fc = JSON.dict(part["functionCall"]) {
            let name = JSON.string(fc["name"]) ?? ""
            let args = JSON.dict(fc["args"]) ?? [:]
            let id = "gemini_fc_\(UUID().uuidString.prefix(8))"
            return .toolUse(ToolUseBlock(id: id, name: name, input: args))
        }
        if let fr = JSON.dict(part["functionResponse"]) {
            let name = JSON.string(fr["name"]) ?? ""
            let response = fr["response"]
            let contentStr: String
            if let s = JSON.string(response) {
                contentStr = s
            } else if let data = JSON.serialize(response ?? [:]) {
                contentStr = String(data: data, encoding: .utf8) ?? ""
            } else {
                contentStr = ""
            }
            return .toolResult(ToolResultBlock(toolUseId: name, content: contentStr))
        }
        return nil
    }

    public static func canonicalToGeminiBody(_ req: CanonicalRequest) -> [String: Any] {
        var body: [String: Any] = [:]
        if let system = req.system {
            body["system_instruction"] = ["parts": [["text": system]]]
        }
        body["contents"] = req.messages.map { canonicalMessageToGemini($0) }
        if !req.tools.isEmpty {
            let decls = req.tools.map { ToolTranslator.canonicalToGemini($0) }
            body["tools"] = [["functionDeclarations": decls]]
        }
        var genConfig: [String: Any] = [:]
        if let maxTokens = req.maxTokens { genConfig["maxOutputTokens"] = Int(maxTokens) }
        if let temp = req.temperature { genConfig["temperature"] = temp }
        if !genConfig.isEmpty { body["generationConfig"] = genConfig }
        return body
    }

    private static func canonicalMessageToGemini(_ msg: CanonicalMessage) -> [String: Any] {
        let role = msg.role == .user ? "user" : "model"
        let parts: [[String: Any]] = msg.content.compactMap { block in
            switch block {
            case .text(let t):
                return ["text": t.text]
            case .toolUse(let tu):
                return ["functionCall": ["name": tu.name, "args": tu.input]]
            case .toolResult(let tr):
                let response: Any
                if let parsed = try? JSONSerialization.jsonObject(with: Data(tr.content.utf8)) {
                    response = parsed
                } else {
                    response = ["result": tr.content]
                }
                return ["functionResponse": ["name": tr.toolUseId, "response": response]]
            default:
                return nil
            }
        }
        return ["role": role, "parts": parts]
    }
}
