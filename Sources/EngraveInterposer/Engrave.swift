import Foundation

/// Engrave: Native macOS AI API translation proxy.
/// Translates between Anthropic, OpenAI (Chat Completions + Responses), and Gemini API formats.
///
/// Usage as library:
/// ```swift
/// let config = EngraveConfig.forLocalMLX(model: "my-model", backendPort: 1234, proxyPort: 8900)
/// let engrave = Engrave(config: config)
/// try await engrave.start()
/// // ... runners connect to localhost:8900
/// await engrave.stop()
/// ```
///
/// Usage as standalone:
/// ```
/// engrave start --port 8900
/// ```
public actor Engrave {
    private var server: ProxyServer?
    private var _config: EngraveConfig
    private var _isRunning = false
    private var logContinuation: AsyncStream<String>.Continuation?
    private var _logStream: AsyncStream<String>?
    private weak var _governance: (any GovernanceEvaluator)?

    /// Whether the proxy server is running
    public var isRunning: Bool { _isRunning }

    /// Current configuration
    public var config: EngraveConfig { _config }

    /// Stream of log messages
    public var logStream: AsyncStream<String> {
        if let existing = _logStream { return existing }
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        self.logContinuation = continuation
        self._logStream = stream
        return stream
    }

    public init(config: EngraveConfig, governance: (any GovernanceEvaluator)? = nil) {
        self._config = config
        self._governance = governance
    }

    /// Set the governance evaluator (can be set after init)
    public func setGovernance(_ governance: (any GovernanceEvaluator)?) {
        self._governance = governance
    }

    /// Start the proxy server
    public func start() async throws {
        guard !_isRunning else { return }

        // Ensure log stream is ready
        if logContinuation == nil {
            let (stream, continuation) = AsyncStream.makeStream(of: String.self)
            self.logContinuation = continuation
            self._logStream = stream
        }

        let logger: LogHandler = { [weak self] message in
            guard let self = self else { return }
            Task { await self.log(message) }
        }

        let server = ProxyServer(config: _config, logger: logger, governance: _governance)
        self.server = server

        try await server.start()

        _isRunning = true
        log("[engrave] starting on \(_config.server.host):\(_config.server.port)")
    }

    /// Stop the proxy server
    public func stop() async {
        guard _isRunning else { return }
        await server?.stop()
        server = nil
        _isRunning = false
        log("[engrave] stopped")
        logContinuation?.finish()
        logContinuation = nil
        _logStream = nil
    }

    /// Update configuration (requires restart to take effect)
    public func updateConfig(_ newConfig: EngraveConfig) {
        _config = newConfig
    }

    /// Convenience: start with a config for local MLX model
    public static func forLocalMLX(
        model: String,
        backendPort: UInt16 = 1234,
        proxyPort: UInt16 = 8900
    ) -> Engrave {
        let config = EngraveConfig.forLocalMLX(model: model, backendPort: backendPort, proxyPort: proxyPort)
        return Engrave(config: config)
    }

    private func log(_ message: String) {
        logContinuation?.yield(message)
    }
}
