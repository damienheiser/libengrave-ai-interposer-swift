import Foundation
import Network

/// NWListener-based HTTP proxy server.
/// Single port, path-based routing to determine source API format.
public actor ProxyServer {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let config: EngraveConfig
    private let backendClient: BackendClient
    private let logger: LogHandler
    private weak var governance: (any GovernanceEvaluator)?
    private var _isRunning = false

    public var isRunning: Bool { _isRunning }

    public init(config: EngraveConfig, logger: @escaping LogHandler, governance: (any GovernanceEvaluator)? = nil) {
        self.config = config
        self.backendClient = BackendClient()
        self.logger = logger
        self.governance = governance
    }

    public func start() throws {
        let port = NWEndpoint.Port(rawValue: config.server.port)!
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: port)
        self.listener = listener

        listener.stateUpdateHandler = { [logger] state in
            switch state {
            case .ready:
                logger("[engrave] server listening on port \(port)")
            case .failed(let error):
                logger("[engrave] server failed: \(error)")
            case .cancelled:
                logger("[engrave] server cancelled")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            Task { await self.handleNewConnection(connection) }
        }

        listener.start(queue: .global(qos: .userInitiated))
        _isRunning = true
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        _isRunning = false
        logger("[engrave] server stopped")
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.receiveRequest(connection: connection, id: id) }
            case .failed, .cancelled:
                Task { await self?.removeConnection(id: id) }
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    private func removeConnection(id: ObjectIdentifier) {
        connections.removeValue(forKey: id)
    }

    private func receiveRequest(connection: NWConnection, id: ObjectIdentifier) {
        // Read up to max body size + reasonable header size
        let maxSize = config.server.maxBodyBytes + 65536

        connection.receive(minimumIncompleteLength: 1, maximumLength: maxSize) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.logger("[engrave] receive error: \(error)")
                connection.cancel()
                return
            }

            guard let data = content, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                    Task { await self.removeConnection(id: id) }
                }
                return
            }

            // We may not have received the full request yet.
            // Check if we have the full body based on Content-Length
            Task {
                let fullData = await self.ensureFullBody(connection: connection, initialData: data, maxSize: maxSize)
                await self.processRequest(connection: connection, data: fullData, id: id)
            }
        }
    }

    /// Ensure we've received the full HTTP body based on Content-Length header
    private nonisolated func ensureFullBody(connection: NWConnection, initialData: Data, maxSize: Int) async -> Data {
        guard let str = String(data: initialData, encoding: .utf8) else { return initialData }

        // Find Content-Length
        let headerEnd: String.Index
        if let range = str.range(of: "\r\n\r\n") {
            headerEnd = range.upperBound
        } else if let range = str.range(of: "\n\n") {
            headerEnd = range.upperBound
        } else {
            return initialData
        }

        // Parse content-length from headers
        let headerSection = str[str.startIndex..<headerEnd].lowercased()
        guard let clRange = headerSection.range(of: "content-length: ") else { return initialData }
        let afterCL = headerSection[clRange.upperBound...]
        let clEnd = afterCL.firstIndex(where: { $0 == "\r" || $0 == "\n" }) ?? afterCL.endIndex
        guard let contentLength = Int(afterCL[afterCL.startIndex..<clEnd]) else { return initialData }

        let headerBytes = str[str.startIndex..<headerEnd].utf8.count
        let expectedTotal = headerBytes + contentLength

        if initialData.count >= expectedTotal { return initialData }

        // Need to read more
        var accumulated = initialData
        let remaining = expectedTotal - accumulated.count

        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { content, _, _, error in
                if let content = content {
                    accumulated.append(content)
                }
                continuation.resume(returning: accumulated)
            }
        }
    }

    private func processRequest(connection: NWConnection, data: Data, id: ObjectIdentifier) async {
        guard let request = HTTPRequest.parse(data) else {
            sendResponse(connection: connection, response: HTTPResponse.error("Invalid HTTP request", status: 400))
            return
        }

        let handler = ConnectionHandler(config: config, backendClient: backendClient, logger: logger, governance: governance)
        let result = await handler.handle(request: request)

        switch result {
        case .complete(let response):
            sendResponse(connection: connection, response: response)

        case .streaming(let context):
            // Send SSE headers first
            let headers = HTTPResponse.sseHeaders()
            connection.send(content: headers, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { _ in })

            // Stream translated events
            let translatedStream = context.translateStream()
            Task {
                do {
                    for try await line in translatedStream {
                        let lineData = Data(line.utf8)
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            connection.send(content: lineData, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { _ in
                                continuation.resume()
                            })
                        }
                    }
                    // Close connection after stream ends
                    connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } catch {
                    self.logger("[engrave] stream send error: \(error)")
                    connection.cancel()
                }
                await self.removeConnection(id: id)
            }
        }
    }

    private nonisolated func sendResponse(connection: NWConnection, response: HTTPResponse) {
        let data = response.serialize()
        connection.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
            if let error = error {
                print("[engrave] send error: \(error)")
            }
            connection.cancel()
        })
    }
}
