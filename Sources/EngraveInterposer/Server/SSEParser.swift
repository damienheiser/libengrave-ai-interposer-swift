import Foundation

/// Parses Server-Sent Events from a byte stream.
/// Handles the "event: ...\ndata: ...\n\n" format used by all AI APIs.
public struct SSEParser {
    private var buffer = ""

    public init() {}

    /// Feed raw text data into the parser. Returns zero or more parsed events.
    public mutating func feed(_ text: String) -> [SSEEvent] {
        buffer += text
        var events: [SSEEvent] = []

        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            var eventType: String? = nil
            var dataLines: [String] = []

            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(line)
                if line.hasPrefix("event: ") || line.hasPrefix("event:") {
                    eventType = String(line.dropFirst(line.hasPrefix("event: ") ? 7 : 6))
                } else if line.hasPrefix("data: ") || line.hasPrefix("data:") {
                    dataLines.append(String(line.dropFirst(line.hasPrefix("data: ") ? 6 : 5)))
                } else if line.hasPrefix(":") {
                    // Comment, ignore
                } else if !line.isEmpty {
                    // Unknown field, treat as data
                    dataLines.append(line)
                }
            }

            if !dataLines.isEmpty {
                let dataStr = dataLines.joined(separator: "\n")

                // Check for [DONE] sentinel (Chat Completions)
                if dataStr.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                    events.append(SSEEvent(eventType: eventType, data: nil, rawData: "[DONE]"))
                    continue
                }

                // Try parsing as JSON
                if let jsonData = dataStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    events.append(SSEEvent(eventType: eventType, data: json, rawData: dataStr))
                } else {
                    events.append(SSEEvent(eventType: eventType, data: nil, rawData: dataStr))
                }
            }
        }

        return events
    }

    /// Reset parser state
    public mutating func reset() {
        buffer = ""
    }
}

/// A parsed Server-Sent Event
public struct SSEEvent {
    /// The event type (from "event:" line), nil if not specified
    public let eventType: String?
    /// Parsed JSON data, nil if not valid JSON or [DONE]
    public let data: [String: Any]?
    /// Raw data string
    public let rawData: String

    public var isDone: Bool { rawData == "[DONE]" }
}
