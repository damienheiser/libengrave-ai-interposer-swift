import Foundation

// MARK: - Block Type

public enum BlockType: String, Sendable {
    case text
    case toolUse = "tool_use"
    case thinking
}

// MARK: - Canonical Stream Events

public enum CanonicalStreamEvent: Sendable {
    case messageStart(messageId: String)
    case contentBlockStart(index: UInt32, blockType: BlockType, toolUseId: String?, toolName: String?)
    case textDelta(index: UInt32, text: String)
    case toolInputDelta(index: UInt32, partialJson: String)
    case contentBlockEnd(index: UInt32)
    case messageDelta(stopReason: StopReason, usage: Usage?)
    case messageEnd
    case error(message: String, code: String?)
}
