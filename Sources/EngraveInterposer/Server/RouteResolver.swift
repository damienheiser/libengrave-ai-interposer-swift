import Foundation

/// Resolved route: which backend to call with what model
public struct ResolvedRoute {
    public let backend: String
    public let provider: String
    public let model: String
    public let providerConfig: EngraveConfig.ProviderConfig?

    public init(backend: String, provider: String, model: String, providerConfig: EngraveConfig.ProviderConfig? = nil) {
        self.backend = backend
        self.provider = provider
        self.model = model
        self.providerConfig = providerConfig
    }
}

/// Resolves incoming requests to backend targets.
/// Priority: aliases → default routes → passthrough
public struct RouteResolver {
    private let config: EngraveConfig

    public init(config: EngraveConfig) {
        self.config = config
    }

    /// Resolve a route for the given source facade and model name
    public func resolve(sourceProvider: String, model: String) -> ResolvedRoute {
        // 1. Check aliases (highest priority)
        if let alias = config.routes.aliases[model] {
            let providerName = alias.provider ?? alias.backend
            return ResolvedRoute(
                backend: alias.backend,
                provider: providerName,
                model: alias.model,
                providerConfig: config.providers[providerName]
            )
        }

        // 2. Check default routes for this facade
        if let defaultRoute = config.routes.defaults[sourceProvider] {
            let providerName = defaultRoute.provider ?? defaultRoute.backend
            // "*" means passthrough the original model name
            let resolvedModel = defaultRoute.model == "*" ? model : defaultRoute.model
            return ResolvedRoute(
                backend: defaultRoute.backend,
                provider: providerName,
                model: resolvedModel,
                providerConfig: config.providers[providerName]
            )
        }

        // 3. Passthrough: same provider, same model
        return ResolvedRoute(
            backend: sourceProvider,
            provider: sourceProvider,
            model: model,
            providerConfig: nil
        )
    }

    /// Determine the source provider from the request path
    public static func sourceProvider(for path: String) -> (provider: String, model: String?) {
        if path.hasPrefix("/v1/messages") {
            return ("anthropic", nil)
        }
        if path.hasPrefix("/v1/chat/completions") {
            return ("openai_compatible", nil)
        }
        if path.hasPrefix("/v1/responses") {
            return ("openai", nil)
        }
        // Gemini: /v1/models/{model}:generateContent or :streamGenerateContent
        if path.hasPrefix("/v1/models/") && (path.contains(":generateContent") || path.contains(":streamGenerateContent")) {
            // Extract model name from path
            let afterModels = path.dropFirst("/v1/models/".count)
            if let colonIdx = afterModels.firstIndex(of: ":") {
                let model = String(afterModels[afterModels.startIndex..<colonIdx])
                return ("gemini", model)
            }
        }
        return ("unknown", nil)
    }
}
