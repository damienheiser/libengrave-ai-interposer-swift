import Foundation

// MARK: - Provider

public enum Provider: String, Codable, Sendable {
    case anthropic
    case openAI = "openai"
    case openAICompatible = "openai_compatible"
    case gemini
}

// MARK: - Role

public enum Role: String, Codable, Sendable {
    case user
    case assistant
}

// MARK: - Content Blocks

public struct TextBlock: Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct ToolUseBlock: @unchecked Sendable {
    public var id: String
    public var name: String
    public var input: [String: Any]

    public init(id: String, name: String, input: [String: Any]) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ToolResultBlock: Sendable {
    public var toolUseId: String
    public var content: String
    public var isError: Bool

    public init(toolUseId: String, content: String, isError: Bool = false) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }
}

public struct ThinkingBlock: Sendable {
    public var thinking: String
    public var signature: String?

    public init(thinking: String, signature: String? = nil) {
        self.thinking = thinking
        self.signature = signature
    }
}

public struct ImageBlock: Sendable {
    public var mediaType: String
    public var data: String

    public init(mediaType: String, data: String) {
        self.mediaType = mediaType
        self.data = data
    }
}

public enum ContentBlock: Sendable {
    case text(TextBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case thinking(ThinkingBlock)
    case image(ImageBlock)
}

// MARK: - Messages

public struct CanonicalMessage: Sendable {
    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }
}

// MARK: - Tool Definitions

public struct CanonicalToolDef: @unchecked Sendable {
    public var name: String
    public var description: String
    public var parameters: [String: Any]

    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - Request Metadata

public struct RequestMetadata: Sendable {
    public var sourceProvider: Provider
    public var targetProvider: Provider
    public var requestId: String

    public init(sourceProvider: Provider, targetProvider: Provider, requestId: String = UUID().uuidString) {
        self.sourceProvider = sourceProvider
        self.targetProvider = targetProvider
        self.requestId = requestId
    }
}

// MARK: - Request

public struct CanonicalRequest: Sendable {
    public var system: String?
    public var messages: [CanonicalMessage]
    public var tools: [CanonicalToolDef]
    public var model: String
    public var maxTokens: UInt32?
    public var temperature: Float?
    public var stream: Bool
    public var metadata: RequestMetadata

    public init(
        system: String? = nil,
        messages: [CanonicalMessage] = [],
        tools: [CanonicalToolDef] = [],
        model: String = "unknown",
        maxTokens: UInt32? = nil,
        temperature: Float? = nil,
        stream: Bool = false,
        metadata: RequestMetadata = RequestMetadata(sourceProvider: .anthropic, targetProvider: .anthropic)
    ) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stream = stream
        self.metadata = metadata
    }
}

// MARK: - Stop Reason

public enum StopReason: String, Codable, Sendable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case error
}

// MARK: - Usage

public struct Usage: Sendable {
    public var inputTokens: UInt32
    public var outputTokens: UInt32

    public init(inputTokens: UInt32 = 0, outputTokens: UInt32 = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

// MARK: - Response

public struct CanonicalResponse: Sendable {
    public var id: String
    public var model: String
    public var role: Role
    public var content: [ContentBlock]
    public var stopReason: StopReason
    public var usage: Usage

    public init(
        id: String, model: String, role: Role = .assistant,
        content: [ContentBlock] = [], stopReason: StopReason = .endTurn,
        usage: Usage = Usage()
    ) {
        self.id = id
        self.model = model
        self.role = role
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }
}

// MARK: - JSON Helpers

/// Helpers for working with untyped JSON dictionaries
public enum JSON {
    public static func string(_ value: Any?) -> String? {
        value as? String
    }

    public static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    public static func uint32(_ value: Any?) -> UInt32? {
        if let i = JSON.int(value) { return UInt32(i) }
        return nil
    }

    public static func float(_ value: Any?) -> Float? {
        if let d = value as? Double { return Float(d) }
        if let f = value as? Float { return f }
        return nil
    }

    public static func bool(_ value: Any?) -> Bool? {
        value as? Bool
    }

    public static func dict(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    public static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    public static func parse(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public static func serialize(_ obj: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj)
    }

    public static func serializeString(_ obj: Any) -> String? {
        guard let data = serialize(obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
