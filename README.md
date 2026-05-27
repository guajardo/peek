# Peek — MCP Webcam Server

> **Status:** V1.0 (Snapshot-only MVP)  
> **Spec:** MCP 2025-11-25 | Swift 6.0+ | macOS 14.0+

---

## What is Peek?

Peek is a standalone macOS menu bar application that exposes your Mac's webcam as an MCP server, giving any MCP-compatible client (Claude, Codex, Cursor, Hermes Agent, etc.) direct access to capture photos on demand.

### Core Principles

| Principle | Description |
|-----------|-------------|
| **Standalone** | No dependency on Hermes, `.hermes/`, or any agent framework. Runs independently. |
| **Menu bar first** | Visible status indicator (●), start/stop control, port display. User is always aware when the server is alive. |
| **MCP native** | Implements MCP 2025-11-25 spec via `modelcontextprotocol/swift-sdk`. HTTP transport on `127.0.0.1`. |
| **User-controlled** | Manual server start by default. Auto-start is a configurable preference, not default. |
| **Minimal attack surface** | No microphone. No remote binding. macOS camera permission is the only gate. |
| **Audit trail** | Every tool call is logged to `captures.log` as JSONL with timestamp, tool name, and outcome. |

---

## Features

### V1 Feature Matrix

| Feature | Status | Notes |
|---------|--------|-------|
| Menu bar app (LSUIElement) | ✅ | No Dock icon |
| Start/Stop MCP server | ✅ | Manual only, auto-start optional |
| MCP over HTTP (127.0.0.1) | ✅ | Port 8765 default |
| `camera_status` | ✅ | JSON metadata response |
| `camera_list` | ✅ | JSON metadata response |
| `camera_snapshot` | ✅ | ImageContent + metadata text |
| `peek_ping` | ✅ | Debugging tool for MCP transport |
| `camera_capture_frames` | ❌ | V1.1 |
| `camera_record_video` | ❌ | V2.0 |
| Live stream | ❌ | V2.0 |
| Configuration UI | ❌ | V1.5 |
| Microphone / audio | ❌ | Not V1 |
| Auth token | ❌ | V1.5 |

---

## Quick Start

### Install via Homebrew (recommended)

```bash
brew install peek
open Peek.app
```

> **Note:** A pre-built formula will be available once V1.0 is released. Track progress in [CHANGELOG.md](CHANGELOG.md).

### Build from source

```bash
# Clone the repo
git clone https://github.com/guajardo/peek.git
cd peek

# Build
swift build -c release

# Create app bundle (macOS)
make app
```

### Configure your MCP client

**Claude Desktop** (`~/.claude.json`):
```json
{
  "mcpServers": {
    "peek": {
      "url": "http://127.0.0.1:8765/mcp"
    }
  }
}
```

**Other MCP clients** (Codex, Cursor, etc.):
Use the same endpoint: `http://127.0.0.1:8765/mcp`

### Run

1. Open `Peek.app` — menu bar icon appears
2. Click **Start Server**
3. The camera permission prompt may appear on first use — grant access
4. Your MCP client can now call `camera_snapshot`, `camera_status`, and `camera_list`

---

## Security

- **Local-only binding**: Server binds to `127.0.0.1` only. Cannot be accessed remotely.
- **No microphone**: V1 has no audio capabilities.
- **Manual start**: Server must be explicitly started by the user.
- **Menu bar visibility**: Status indicator shows when the server is running.
- **Audit log**: Every tool call is logged to `~/Library/Logs/Peek/captures.log`.
- **No auth in V1**: Any process running as the current user with camera permission can call the server. Token auth is planned for V1.5.

---

## Project Structure

```
Peek/
├── App/
│   ├── PeekApp.swift          # Entry point, @main
│   ├── PeekAppDelegate.swift  # NSApplicationDelegate
│   └── PeekController.swift   # @MainActor bridge: UI ↔ serverManager
├── MCP/
│   ├── MCPServerManager.swift     # Actor: HTTP server lifecycle, owns CSC + AuditLogger
│   ├── PeekToolRegistry.swift     # tools/list implementation
│   └── PeekToolHandlers.swift    # All tool handlers (call_tool)
├── Camera/
│   ├── CameraSessionController.swift  # Actor: serializes camera ops, busy policy
│   ├── PermissionService.swift        # macOS camera permission
│   ├── CameraDeviceProvider.swift    # Static device enumeration
│   └── AVFoundationPhotoCapturer.swift # Low-level photo capture
├── Storage/
│   ├── PeekPaths.swift           # All path constants
│   ├── AuditLogger.swift          # Actor: JSONL file append via FileHandle
│   └── SecureImageStore.swift     # Atomic JPEG writes
├── Config/
│   ├── PeekConfig.swift          # All config structs
│   └── ConfigLoader.swift        # load() / save()
├── Models/
│   ├── CameraDevice.swift
│   ├── CaptureQuality.swift
│   ├── CaptureErrors.swift
│   └── CaptureMetadata.swift
└── Views/
    └── MenuBarView.swift
```

> Full implementation contract: [`docs/PEEK-MCP.md`](docs/PEEK-MCP.md)

---

## Roadmap

### V1.0 — Snapshot MVP (current)
- Menu bar app
- Start/Stop server
- `camera_status`, `camera_list`, `camera_snapshot`
- `peek_ping` for debugging
- Audit logging (JSONL)
- Local-only security

### V1.1 — Frame Burst
- `camera_capture_frames` (up to 30 frames)
- Frame burst storage with manifest

### V1.5 — Auth + Config UI
- Local token authentication
- Configuration UI in menu bar
- Auto-start preference UI

### V2.0 — Video + Stream
- `camera_record_video` (MP4 without audio)
- Live stream endpoint
- Remote binding option (with auth)

---

## License

MIT