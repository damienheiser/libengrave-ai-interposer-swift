# MLXLauncher

MLXLauncher is a macOS SwiftUI application that orchestrates local MLX model inference with AI coding assistants. It discovers models on disk, manages an MLX inference server, and launches AI runners -- all through a single unified interface.

## Overview

MLXLauncher provides a complete workflow for running large language models locally on Apple Silicon and connecting them to popular AI coding tools. It handles model discovery, server lifecycle, API translation, and runner configuration so you can focus on using the tools rather than wiring them together.

The app embeds [Engrave](https://github.com/damienheiser/libengrave-ai-swift), a native Swift API translation proxy, so that every runner connects to a single local port (8900) regardless of which API format it speaks. Anthropic, OpenAI, and Gemini protocols are all translated on the fly to the MLX backend.

## Features

- **Model discovery** -- automatically finds MLX models in `~/.lmstudio/models/`
- **Server management** -- starts and stops the MLX inference server (`mlx_lm`), which exposes an OpenAI-compatible API
- **API translation** -- the embedded Engrave interposer translates between Anthropic, OpenAI, and Gemini API formats on a single port (8900)
- **Runner integration** -- launches Claude Code, Codex, Gemini CLI, Aider, and gptme with environment variables pointing to the interposer
- **Generation profiles** -- configurable temperature, top_p, top_k, and other sampling parameters
- **Web UI and REST API** -- embedded interface on port 8421 for monitoring and control
- **SwiftUI interface** -- 3-column layout with model list, runner configuration, and server controls
- **No external dependencies** -- built entirely on Foundation and Network frameworks

## Requirements

- macOS 14+
- Swift 5.9
- Apple Silicon Mac (for MLX inference)

## Build

```
swift build
```

## Run

```
.build/debug/MLXLauncher
```

## Project Structure

```
Package.swift             Swift Package manifest (depends on local Engrave/)
Sources/                  SwiftUI application source
Engrave/                  Native Swift API translation proxy (subpackage)
  Sources/EngraveLib/     Library target
  Sources/EngraveCLI/     Standalone CLI target
```

## Architecture

MLXLauncher is organized around three layers:

1. **Model layer** -- discovers and tracks MLX models on disk, manages generation profiles.
2. **Server layer** -- controls the `mlx_lm` inference server lifecycle and monitors its health.
3. **Runner layer** -- launches AI coding assistants, injecting the correct environment variables so each runner talks to the Engrave interposer on port 8900.

The Engrave interposer sits between the runners and the MLX backend. It accepts requests in any supported API format (Anthropic Messages, OpenAI Chat Completions, OpenAI Responses, Gemini) and translates them into the format the backend expects. This means every runner can use its native protocol without modification.

## Related Projects

The Engrave package embedded in this repository is also available as a standalone library:
[github.com/damienheiser/libengrave-ai-swift](https://github.com/damienheiser/libengrave-ai-swift)

## License

MIT
