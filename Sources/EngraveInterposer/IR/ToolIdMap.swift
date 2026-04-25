import Foundation

/// Bidirectional mapping between host runner tool call IDs and target backend tool call IDs.
/// Must persist across HTTP requests within a session for multi-turn tool use.
public final class ToolIdMap: @unchecked Sendable {
    private let lock = NSLock()
    /// host_id -> target_id
    private var forward: [String: String] = [:]
    /// target_id -> host_id
    private var reverse: [String: String] = [:]
    private var nextId: UInt32 = 1

    public init() {}

    /// When the target model returns a tool call with `targetId`,
    /// generate a host-format ID and store the bidirectional mapping.
    public func registerFromTarget(_ targetId: String, hostProvider: Provider) -> String {
        lock.lock()
        defer { lock.unlock() }

        let seq = nextId
        nextId += 1

        let hostId: String
        switch hostProvider {
        case .anthropic:
            hostId = String(format: "toolu_%012x", seq)
        case .openAI, .openAICompatible:
            hostId = String(format: "call_%012x", seq)
        case .gemini:
            hostId = "gemini_\(seq)"
        }

        forward[hostId] = targetId
        reverse[targetId] = hostId
        return hostId
    }

    /// When the host runner sends a tool result referencing `hostId`,
    /// look up the corresponding target_id.
    public func resolveToTarget(_ hostId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return forward[hostId]
    }

    /// When the target model references a tool call by `targetId`,
    /// look up the corresponding host_id.
    public func resolveToHost(_ targetId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return reverse[targetId]
    }
}
