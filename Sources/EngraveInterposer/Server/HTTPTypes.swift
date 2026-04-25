import Foundation

/// Parsed HTTP request
public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// Parse raw HTTP/1.1 request data
    public static func parse(_ data: Data) -> HTTPRequest? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }

        // Split headers from body
        let headerBodySplit: [String]
        if let range = str.range(of: "\r\n\r\n") {
            headerBodySplit = [String(str[str.startIndex..<range.lowerBound]), String(str[range.upperBound...])]
        } else if let range = str.range(of: "\n\n") {
            headerBodySplit = [String(str[str.startIndex..<range.lowerBound]), String(str[range.upperBound...])]
        } else {
            return nil
        }

        let headerSection = headerBodySplit[0]
        let bodyStr = headerBodySplit.count > 1 ? headerBodySplit[1] : ""

        let lines = headerSection.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .carriageReturn) }
        guard !lines.isEmpty else { return nil }

        // Parse request line
        let requestLine = lines[0].split(separator: " ", maxSplits: 2)
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        // Parse headers
        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { continue }
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let bodyData = Data(bodyStr.utf8)
        return HTTPRequest(method: method, path: path, headers: headers, body: bodyData)
    }

    /// Get JSON body
    public var jsonBody: [String: Any]? {
        JSON.parse(body)
    }
}

private extension Character {
    static let carriageReturn = Character("\r")
}

private extension StringProtocol {
    func trimmingCharacters(in char: Character) -> String {
        var result = String(self)
        while result.last == char { result.removeLast() }
        while result.first == char { result.removeFirst() }
        return result
    }
}

/// HTTP response builder
public struct HTTPResponse {
    public let statusCode: Int
    public let statusText: String
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, statusText: String, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.statusText = statusText
        self.headers = headers
        self.body = body
    }

    /// Build HTTP/1.1 response data
    public func serialize() -> Data {
        var allHeaders = headers
        if allHeaders["content-length"] == nil && allHeaders["transfer-encoding"] == nil {
            allHeaders["content-length"] = "\(body.count)"
        }

        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        for (key, value) in allHeaders {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    // MARK: - Convenience Constructors

    public static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let body = JSON.serialize(obj) ?? Data()
        return HTTPResponse(
            statusCode: status, statusText: statusText(for: status),
            headers: [
                "content-type": "application/json",
                "access-control-allow-origin": "*",
            ],
            body: body
        )
    }

    public static func error(_ message: String, status: Int = 500) -> HTTPResponse {
        json(["error": ["type": "api_error", "message": message]], status: status)
    }

    /// Build SSE response headers (no body — chunks will be sent separately)
    public static func sseHeaders(extraHeaders: [String: String] = [:]) -> Data {
        var response = "HTTP/1.1 200 OK\r\n"
        response += "content-type: text/event-stream\r\n"
        response += "cache-control: no-cache\r\n"
        response += "connection: keep-alive\r\n"
        response += "access-control-allow-origin: *\r\n"
        for (key, value) in extraHeaders {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        return Data(response.utf8)
    }

    /// CORS preflight response
    public static func cors() -> HTTPResponse {
        HTTPResponse(
            statusCode: 204, statusText: "No Content",
            headers: [
                "access-control-allow-origin": "*",
                "access-control-allow-methods": "GET, POST, OPTIONS",
                "access-control-allow-headers": "content-type, authorization, x-api-key, anthropic-version",
                "access-control-max-age": "86400",
            ]
        )
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
