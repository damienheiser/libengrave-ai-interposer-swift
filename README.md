# libengrave-ai-interposer-swift

A native Swift library for translating between AI provider APIs in real time. Enables any AI client to communicate with any AI backend by converting requests and streaming responses through a canonical intermediate representation.

## What It Does

An AI coding assistant like Claude Code speaks the Anthropic Messages API. A local MLX model server speaks OpenAI Chat Completions. This library sits between them and translates on the fly -- including streaming SSE events, tool calls, and tool results.

```
Claude Code (Anthropic API)  -->  Engrave Interposer  -->  MLX Server (OpenAI API)
Codex CLI (OpenAI API)       -->  Engrave Interposer  -->  Anthropic Cloud API
Gemini CLI (Gemini API)      -->  Engrave Interposer  -->  Any Backend
```

## Supported API Formats

| Format | Inbound (parse) | Outbound (serialize) | Streaming |
|--------|:---:|:---:|:---:|
| Anthropic Messages API | Yes | Yes | Yes |
| OpenAI Chat Completions | Yes | Yes | Yes |
| OpenAI Responses API | Yes | Yes | Yes |
| Google Gemini API | Yes | Yes | Yes |

## Features

### Canonical IR (Intermediate Representation)
Every request and response passes through a provider-agnostic intermediate format:
- `CanonicalRequest` -- system prompt, messages, tools, model, temperature, stream flag
- `CanonicalMessage` -- role (user/assistant) with content blocks
- `ContentBlock` -- text, tool_use, tool_result, thinking, image
- `CanonicalStreamEvent` -- message_start, content_block_start, text_delta, tool_input_delta, content_block_end, message_delta, message_end

### Message Translation
- Parse and serialize request bodies for all 4 API formats
- System prompt extraction (Anthropic `system`, OpenAI `instructions`, Chat Completions `system`/`developer` role, Gemini `system_instruction`)
- Tool definition conversion between formats (Anthropic `input_schema`, OpenAI `parameters`, Gemini `functionDeclarations`)
- Tool call/result mapping with proper role handling (Anthropic tool_result in user message, OpenAI function_call_output as top-level item, Chat Completions tool role, Gemini functionResponse)
- Content block translation (text, tool_use, tool_result, thinking, image)

### Stream Translation
- State machine (`idle -> inMessage -> inBlock -> inMessage -> done`) for reliable stream conversion
- Anthropic SSE events: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`
- OpenAI Responses SSE: `response.created`, `response.output_item.added`, `response.output_text.delta`, `response.function_call_arguments.delta`, `response.completed`
- Chat Completions SSE: chunked `chat.completion.chunk` objects with `[DONE]` terminator
- Gemini SSE: complete candidate objects with accumulated text delta tracking
- Tool input streaming: buffers partial JSON across delta events

### Tool ID Mapping
- Bidirectional mapping between provider-specific tool call IDs
- Generates format-appropriate IDs: `toolu_XXXX` (Anthropic), `call_XXXX` (OpenAI), `gemini_N` (Gemini)
- Persists across multi-turn tool use conversations

### HTTP Proxy Server
- NWListener-based server (Network.framework, no external dependencies)
- Single port, path-based routing:
  - `POST /v1/messages` -- Anthropic facade
  - `POST /v1/chat/completions` -- Chat Completions facade
  - `POST /v1/responses` -- OpenAI Responses facade
  - `POST /v1/models/{model}:generateContent` -- Gemini facade
  - `POST /v1/models/{model}:streamGenerateContent` -- Gemini streaming facade
  - `GET /v1/models` -- model list
  - `GET /health` -- health check
- CORS support with preflight handling
- Chunked transfer encoding for SSE streaming
- Configurable max request body size

### Route Resolution
Three-tier resolution with priority:
1. **Aliases** -- exact model name match (e.g., `"claude-fast" -> anthropic/claude-haiku`)
2. **Default routes** -- per-facade defaults (e.g., all Anthropic requests -> local backend)
3. **Passthrough** -- forward to same provider with same model
- `"*"` model name passes through the client's original model name

### Backend Client
- URLSession with async byte streaming for SSE
- Per-provider API key resolution: config env var -> `INTERPOSER_*_API_KEY` -> standard env vars
- Extra headers support for custom providers (OpenRouter, etc.)
- Automatic endpoint URL construction per backend type

### Configuration
JSON-based configuration with route tables, provider definitions, and aliases:
```json
{
  "server": { "host": "127.0.0.1", "port": 8900 },
  "routes": {
    "default": {
      "anthropic": { "backend": "local", "model": "*" },
      "openai_compatible": { "backend": "local", "model": "*" }
    },
    "aliases": {
      "claude-fast": { "backend": "anthropic", "model": "claude-haiku-4-5" }
    }
  },
  "providers": {
    "local": { "type": "chat_completions", "base_url": "http://localhost:1234" }
  }
}
```

### Governance Integration
- `GovernanceEvaluator` protocol for plugging in policy engines
- Pre-request evaluation with block/allow decisions
- Stream event evaluation
- Tool call evaluation
- Optional -- interposer works without governance

## Requirements

- macOS 14.0+
- Swift 5.9+
- No external dependencies (Foundation + Network frameworks only)

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/damienheiser/libengrave-ai-interposer-swift.git", branch: "main"),
]

// In your target:
.product(name: "EngraveInterposer", package: "libengrave-ai-interposer-swift")
```

## Usage

### As an In-Process Proxy

```swift
import EngraveInterposer

// Create config for a local MLX model server
let config = EngraveConfig.forLocalMLX(
    model: "my-model",
    backendPort: 1234,   // MLX server port
    proxyPort: 8900      // Interposer port
)

let engrave = Engrave(config: config)
try await engrave.start()

// Now any AI runner can connect to localhost:8900:
// - Claude Code: ANTHROPIC_BASE_URL=http://localhost:8900
// - Codex: OPENAI_BASE_URL=http://localhost:8900/v1
// - Gemini CLI: GOOGLE_GEMINI_BASE_URL=http://localhost:8900

// Stream log messages
for await message in await engrave.logStream {
    print(message)
}

await engrave.stop()
```

### Direct Translation (No Server)

```swift
import EngraveInterposer

// Parse an Anthropic request
let anthropicBody: [String: Any] = [
    "model": "claude-3-sonnet",
    "max_tokens": 1024,
    "messages": [["role": "user", "content": "Hello"]],
    "stream": true
]
let canonical = MessageTranslator.parseAnthropicRequest(anthropicBody)

// Convert to Chat Completions format
let chatBody = MessageTranslator.canonicalToChatCompletionsBody(canonical)

// Convert to Gemini format
let geminiBody = MessageTranslator.canonicalToGeminiBody(canonical)

// Stream translation
let translator = StreamTranslator()
let events = translator.parseChatCompletionsSSE(data: sseChunk)
for event in events {
    let anthropicLines = translator.canonicalToAnthropicSSE(event)
}
```

### Custom Configuration

```swift
var config = EngraveConfig(
    server: .init(port: 9000),
    routes: .init(
        defaults: [
            "anthropic": .init(backend: "openrouter", model: "anthropic/claude-sonnet-4"),
        ],
        aliases: [
            "fast": .init(backend: "local", model: "llama-3-8b"),
            "smart": .init(backend: "anthropic", model: "claude-opus-4"),
        ]
    ),
    providers: [
        "local": .init(type: "chat_completions", baseURL: "http://localhost:1234"),
        "openrouter": .init(
            type: "chat_completions",
            baseURL: "https://openrouter.ai/api",
            apiKeyEnv: "OPENROUTER_API_KEY"
        ),
    ]
)
```

## API Reference

### Core Types
| Type | Description |
|------|-------------|
| `Engrave` | Main facade actor -- `start()`, `stop()`, `isRunning`, `logStream` |
| `EngraveConfig` | Server, routes, providers configuration |
| `CanonicalRequest` | Provider-agnostic request format |
| `CanonicalMessage` | Role + content blocks |
| `ContentBlock` | `.text`, `.toolUse`, `.toolResult`, `.thinking`, `.image` |
| `CanonicalStreamEvent` | Streaming event types |
| `Provider` | `.anthropic`, `.openAI`, `.openAICompatible`, `.gemini` |

### Translators
| Type | Description |
|------|-------------|
| `MessageTranslator` | Parse/serialize request bodies for all formats |
| `StreamTranslator` | SSE event translation state machine |
| `ToolTranslator` | Tool definition format conversion |
| `SSEParser` | Generic SSE line parser |

### Server
| Type | Description |
|------|-------------|
| `ProxyServer` | NWListener HTTP server with path-based routing |
| `ConnectionHandler` | Per-connection proxy pipeline |
| `RouteResolver` | Alias -> default -> passthrough resolution |
| `BackendClient` | URLSession streaming HTTP client |

## License

MIT
