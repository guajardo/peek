# Repository Guidelines

## Project Structure & Module Organization

Peek is a Swift Package Manager macOS menu bar app. Application code lives in `Sources/Peek/`:

| File | Responsibility |
|------|---------------|
| `PeekApp.swift` | AppKit NSStatusItem, menu bar UI, server lifecycle |
| `MCPServer.swift` | MCP HTTP/JSON-RPC server via NWListener on 127.0.0.1:8765/mcp |
| `Camera.swift` | AVFoundation capture session, photo/video/frame burst |
| `Logger.swift` | JSONL audit events to `~/Library/Logs/Peek/captures.log` |
| `PeekError.swift` | Domain error types |

Resources under `Resources/` (Info.plist, Peek.entitlements, Assets.xcassets/). `Package.swift` defines the `Peek` executable target.

Private development artifacts live in `docs/` (internal specs, plans) and `test/` (smoke tests). Do not reference these in public-facing documentation.

## Build, Test, and Development Commands

| Command | Purpose |
|---------|---------|
| `swift build` | Compile debug executable |
| `swift build -c release` | Produce release binary at `.build/release/Peek` |
| `.build/debug/Peek` | Run Peek with debug build |
| `.build/debug/Peek --start-server` | Launch and auto-start MCP server |

For MCP smoke testing, use the private `test/test_mcp.py` script (requires Peek running).

There is no Swift test target. Verify behavior with `swift build` + smoke test + manual menu bar testing.

## Coding Style & Naming Conventions

- Swift 5.9, 4-space indentation, `final class` where subclassing not intended
- `private` for implementation details
- Types: `UpperCamelCase`, methods/properties: `lowerCamelCase`
- MCP tool names: stable `snake_case` (`camera_snapshot`, `peek_ping`) — clients depend on these
- Small, focused files matching the main type name

## Commit & Pull Request Guidelines

Use conventional commits: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`.

PRs should include: behavior summary, verification commands, linked issues, screenshots for UI changes. Note camera permission, port 8765, or MCP client compatibility impact.

## Security & Configuration Tips

- Server binds to `127.0.0.1` only — no remote access
- No auth in V1 — any MCP client on the local machine can call tools
- Do not log image/video data, secrets, or full request payloads
- Camera permission is the primary privacy gate
- User controls server start/stop manually

## Storage Paths

| Purpose | Path |
|---------|------|
| Captures (photos/video) | `~/Library/Application Support/Peek/Captures/` |
| Audit log | `~/Library/Logs/Peek/captures.log` |
| Config (future) | `~/Library/Application Support/Peek/config.json` |

## Adding MCP Tools

1. Add tool handler in `MCPServer.swift` (match snake_case name)
2. Implement capture logic in `Camera.swift` or delegate to existing methods
3. Log the call in `Logger.swift` (JSONL format: timestamp, tool, params, result, error)
4. Update `docs/MCP-HERMES-INTEGRATION.md` with tool schema
5. Update CHANGELOG.md under `[Unreleased]`

## Platform Requirements

- macOS 11+ (Big Sur or later)
- Camera permission (macOS system prompt)
- Port 8765 available (no other process using it)