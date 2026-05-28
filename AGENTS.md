# Repository Guidelines

## Project Structure & Module Organization

Peek is a Swift Package Manager macOS menu bar app. Application code lives in `Sources/Peek/`: `PeekApp.swift` owns the AppKit status item, `MCPServer.swift` implements the local MCP HTTP/JSON-RPC server, `Camera.swift` wraps AVFoundation capture, and `Logger.swift` writes audit events. macOS bundle metadata and icons are under `Resources/` (`Info.plist`, `Peek.entitlements`, `Assets.xcassets/`). `Package.swift` defines the `Peek` executable target. `test_mcp.py` is a local smoke-test script for the MCP endpoint. Longer implementation notes and diagnostics live in `docs/`.

## Build, Test, and Development Commands

- `swift build` - compile the debug executable.
- `swift build -c release` - produce `.build/release/Peek` for local packaging or manual runs.
- `.build/debug/Peek --start-server` - launch Peek and start the MCP server immediately.
- `python3 test_mcp.py` - exercise `initialize`, `tools/list`, `peek_ping`, and a 404 path against `127.0.0.1:8765`; run Peek first.

There is no dedicated Swift test target yet, so use `swift build` plus the Python smoke test for verification.

## Coding Style & Naming Conventions

Use Swift 5.9 style with 4-space indentation, `final class` where subclassing is not intended, and `private` access for implementation details. Name types in `UpperCamelCase` and methods/properties in `lowerCamelCase`. Keep MCP tool names stable and snake_case (`camera_snapshot`, `peek_ping`) because clients depend on those strings. Prefer small, focused files matching the main type name.

## Testing Guidelines

Add Swift unit tests under `Tests/PeekTests/` if behavior becomes testable without camera permissions. For server protocol changes, update or extend `test_mcp.py` with explicit request/response checks. When changing camera, storage, or logging behavior, verify the relevant file paths under `~/Library/Application Support/Peek/` and `~/Library/Logs/Peek/`.

## Commit & Pull Request Guidelines

Recent history uses concise conventional commits such as `feat: implement MCPServer with NWListener`, `docs: update CHANGELOG...`, and `chore: bootstrap...`. Keep commits scoped and imperative. Pull requests should include a short behavior summary, verification commands run, linked issues when applicable, and screenshots or short screen recordings for menu bar UI changes. Note any camera permission, local port, or MCP client compatibility impact.

## Security & Configuration Tips

Keep the server bound to `127.0.0.1` unless authentication and configuration UI are implemented. Do not log image data, video data, secrets, or full request payloads. Preserve manual user control over starting the server and macOS camera permission as the primary privacy gates.
