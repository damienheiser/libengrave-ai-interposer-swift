import Foundation

/// Configuration for the Engrave interposer proxy.
/// Uses JSON format for easy integration with Foundation.
public struct EngraveConfig: Codable, Sendable {

    /// Server configuration
    public var server: ServerConfig

    /// Route configuration
    public var routes: RouteConfig

    /// Provider backends
    public var providers: [String: ProviderConfig]

    /// Governance configuration
    public var governance: GovernanceConfig?

    public init(
        server: ServerConfig = ServerConfig(),
        routes: RouteConfig = RouteConfig(),
        providers: [String: ProviderConfig] = [:],
        governance: GovernanceConfig? = nil
    ) {
        self.server = server
        self.routes = routes
        self.providers = providers
        self.governance = governance
    }

    // MARK: - Server Config

    public struct ServerConfig: Codable, Sendable {
        public var host: String
        public var port: UInt16
        public var maxBodyBytes: Int

        public init(host: String = "127.0.0.1", port: UInt16 = 8900, maxBodyBytes: Int = 10_485_760) {
            self.host = host
            self.port = port
            self.maxBodyBytes = maxBodyBytes
        }
    }

    // MARK: - Route Config

    public struct RouteConfig: Codable, Sendable {
        /// Default routes per source facade
        public var defaults: [String: RouteTarget]
        /// Model name aliases
        public var aliases: [String: RouteTarget]

        public init(defaults: [String: RouteTarget] = [:], aliases: [String: RouteTarget] = [:]) {
            self.defaults = defaults
            self.aliases = aliases
        }

        enum CodingKeys: String, CodingKey {
            case defaults = "default"
            case aliases
        }
    }

    public struct RouteTarget: Codable, Sendable {
        public var backend: String
        public var model: String
        public var provider: String?

        public init(backend: String, model: String, provider: String? = nil) {
            self.backend = backend
            self.model = model
            self.provider = provider
        }
    }

    // MARK: - Provider Config

    public struct ProviderConfig: Codable, Sendable {
        public var type: String
        public var baseURL: String?
        public var apiKeyEnv: String?
        public var models: [String]?
        public var extraHeaders: [String: String]?

        public init(type: String = "chat_completions", baseURL: String? = nil, apiKeyEnv: String? = nil,
                    models: [String]? = nil, extraHeaders: [String: String]? = nil) {
            self.type = type
            self.baseURL = baseURL
            self.apiKeyEnv = apiKeyEnv
            self.models = models
            self.extraHeaders = extraHeaders
        }

        enum CodingKeys: String, CodingKey {
            case type
            case baseURL = "base_url"
            case apiKeyEnv = "api_key_env"
            case models
            case extraHeaders = "extra_headers"
        }
    }

    // MARK: - Governance Config

    public struct GovernanceConfig: Codable, Sendable {
        public var enabled: Bool
        public var profile: String?
        public var rules: [RuleConfig]?
        public var eventLogPath: String?

        public init(enabled: Bool = false, profile: String? = "standard", rules: [RuleConfig]? = nil,
                    eventLogPath: String? = nil) {
            self.enabled = enabled
            self.profile = profile
            self.rules = rules
            self.eventLogPath = eventLogPath
        }

        enum CodingKeys: String, CodingKey {
            case enabled, profile, rules
            case eventLogPath = "event_log_path"
        }
    }

    public struct RuleConfig: Codable, Sendable {
        public var name: String
        public var severity: String
        public var trigger: String
        public var matchPatterns: [String]?
        public var condition: String?
        public var enabled: Bool
        public var modification: String?
        public var replacement: String?

        public init(name: String, severity: String = "warn", trigger: String = "request",
                    matchPatterns: [String]? = nil, condition: String? = nil, enabled: Bool = true,
                    modification: String? = nil, replacement: String? = nil) {
            self.name = name
            self.severity = severity
            self.trigger = trigger
            self.matchPatterns = matchPatterns
            self.condition = condition
            self.enabled = enabled
            self.modification = modification
            self.replacement = replacement
        }

        enum CodingKeys: String, CodingKey {
            case name, severity, trigger, enabled, modification, replacement
            case matchPatterns = "match_patterns"
            case condition
        }
    }

    // MARK: - Loading

    /// Load config from JSON file
    public static func load(from path: String) throws -> EngraveConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(EngraveConfig.self, from: data)
    }

    /// Load config from default locations (project → user → defaults)
    public static func loadDefault() -> EngraveConfig {
        let projectPath = ".engrave/config.json"
        let userPath = ("~/.config/engrave/config.json" as NSString).expandingTildeInPath

        if let config = try? load(from: projectPath) { return config }
        if let config = try? load(from: userPath) { return config }
        return EngraveConfig()
    }

    /// Create a config for local MLX server proxying.
    /// Uses "*" as the model name to passthrough whatever model the client requests.
    public static func forLocalMLX(
        model: String,
        backendPort: UInt16 = 1234,
        proxyPort: UInt16 = 8900
    ) -> EngraveConfig {
        EngraveConfig(
            server: ServerConfig(port: proxyPort),
            routes: RouteConfig(
                defaults: [
                    "anthropic": RouteTarget(backend: "local", model: "*"),
                    "openai": RouteTarget(backend: "local", model: "*"),
                    "openai_compatible": RouteTarget(backend: "local", model: "*"),
                    "gemini": RouteTarget(backend: "local", model: "*"),
                ]
            ),
            providers: [
                "local": ProviderConfig(
                    type: "chat_completions",
                    baseURL: "http://localhost:\(backendPort)",
                    models: [model]
                ),
            ]
        )
    }

    /// Save config to JSON file
    public func save(to path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }
}
