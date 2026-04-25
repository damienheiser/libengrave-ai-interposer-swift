import Foundation

/// Translates tool definitions between Anthropic, OpenAI, and Gemini formats.
public enum ToolTranslator {

    // MARK: - Anthropic

    public static func anthropicToCanonical(_ tool: [String: Any]) -> CanonicalToolDef? {
        guard let name = JSON.string(tool["name"]),
              let desc = JSON.string(tool["description"]) else { return nil }
        let params = JSON.dict(tool["input_schema"]) ?? ["type": "object"]
        return CanonicalToolDef(name: name, description: desc, parameters: params)
    }

    public static func canonicalToAnthropic(_ tool: CanonicalToolDef) -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "input_schema": tool.parameters,
        ]
    }

    // MARK: - OpenAI (Responses API)

    public static func openAIToCanonical(_ tool: [String: Any]) -> CanonicalToolDef? {
        guard let name = JSON.string(tool["name"]) else { return nil }
        let desc = JSON.string(tool["description"]) ?? ""
        let params = JSON.dict(tool["parameters"]) ?? ["type": "object"]
        return CanonicalToolDef(name: name, description: desc, parameters: params)
    }

    public static func canonicalToOpenAI(_ tool: CanonicalToolDef) -> [String: Any] {
        [
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.parameters,
        ]
    }

    // MARK: - Chat Completions

    public static func chatCompletionsToCanonical(_ tool: [String: Any]) -> CanonicalToolDef? {
        guard let funcDef = JSON.dict(tool["function"]),
              let name = JSON.string(funcDef["name"]) else { return nil }
        let desc = JSON.string(funcDef["description"]) ?? ""
        let params = JSON.dict(funcDef["parameters"]) ?? ["type": "object"]
        return CanonicalToolDef(name: name, description: desc, parameters: params)
    }

    public static func canonicalToChatCompletions(_ tool: CanonicalToolDef) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parameters,
            ] as [String: Any],
        ]
    }

    // MARK: - Gemini

    public static func geminiToCanonical(_ tool: [String: Any]) -> CanonicalToolDef? {
        guard let name = JSON.string(tool["name"]) else { return nil }
        let desc = JSON.string(tool["description"]) ?? ""
        let params = JSON.dict(tool["parameters"]) ?? ["type": "object"]
        return CanonicalToolDef(name: name, description: desc, parameters: params)
    }

    public static func canonicalToGemini(_ tool: CanonicalToolDef) -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.parameters,
        ]
    }
}
