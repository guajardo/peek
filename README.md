# Peek - MCP Webcam Server

> **v1.0.3** - Production V1: photos, video, frame bursts. Nothing more.

---

## What is Peek?

Menu bar macOS app that exposes your webcam as a local MCP server. Any MCP client (Claude, Codex, Cursor, Hermes Agent, or another Streamable HTTP client) connects to `http://127.0.0.1:8765/mcp` and calls tools to capture photos, video, and frame bursts.

### Core Principles

| Principle | Description |
|-----------|-------------|
| **Standalone** | No dependencies. Pure Swift + AVFoundation + Network framework. |
| **Menu bar only** | No Dock icon. Status always visible. Start/Stop with one click. |
| **Local-only** | Server binds to 127.0.0.1. No remote access. |
| **User-controlled** | Manual server start. You decide when it's running. |
| **Storage on disk** | Photos and videos saved to `~/Library/Application Support/Peek/Captures/` |

---

## Features

| Feature | Status |
|---------|--------|
| Menu bar app (LSUIElement) | ✅ |
| Start/Stop server | ✅ |
| `peek_ping` | ✅ |
| `camera_status` | ✅ |
| `camera_snapshot` | ✅ |
| `camera_start_recording` | ✅ |
| `camera_stop_recording` | ✅ |
| `camera_frames` | ✅ |
| Photo storage on disk | ✅ |
| Video storage on disk | ✅ |
| Audit log (JSONL) | ✅ |
| Local release verification | ✅ |

---

## Install

### Homebrew (recommended for users)

```bash
brew install guajardo/tap/peek
Peek --start-server
```

The Homebrew formula installs the `Peek` executable. Running it starts the menu bar app; `--start-server` starts the local MCP server immediately.

### Build from source (for development)

```bash
git clone https://github.com/guajardo/peek.git
cd peek
scripts/build_app_bundle.sh
open dist/Peek.app
```

`scripts/build_app_bundle.sh` creates an ad-hoc signed local app bundle at `dist/Peek.app`. A notarized cask/DMG is outside the V1 release scope.

### Verify release locally

```bash
scripts/verify_release.sh
```

---

## Configure MCP Client

Use the same Streamable HTTP endpoint in any MCP client:

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

**Other MCP clients:** `http://127.0.0.1:8765/mcp`

---

## Usage

1. Open Peek — camera icon appears in menu bar
2. Click **Start Server**
3. Grant camera permission when prompted
4. MCP client connects and can call tools

## Tool Behavior

- MCP handshake supports protocol versions `2025-06-18`, `2025-03-26`, and `2024-11-05`.
- Tool calls return MCP `content`, `structuredContent`, and `isError` fields.
- `camera_status` returns `server_running`, `camera_permission`, and `camera_active`.
- `camera_snapshot` and `camera_frames` accept `quality` values of `low`, `medium`, or `high`.
- Quality maps to the requested AVFoundation session preset when Peek creates a new capture session. If the camera is already active, the existing session preset is reused. Actual dimensions still depend on the camera and macOS capture format; on the current verification machine, both `low` and `high` snapshots returned `1920x1080`.
- Invalid `quality` values and invalid frame counts are rejected before camera work starts.
- Only one video recording can be active at a time; duplicate starts return `Camera is busy`.

---

## Project Structure

```
Peek/
├── Sources/Peek/
│   ├── PeekApp.swift      # AppKit status item + menu bar UI
│   ├── MCPServer.swift    # MCP HTTP/JSON-RPC server via NWListener
│   ├── Camera.swift       # AVFoundation capture
│   ├── Logger.swift       # JSONL audit logging
│   └── PeekError.swift    # Error types
├── Resources/
│   ├── Info.plist
│   ├── Peek.entitlements
│   └── Assets.xcassets/
├── Package.swift
├── PeekFormula.rb
├── scripts/
├── AGENTS.md              # AI agent guidelines
├── CHANGELOG.md
└── README.md
```

Core app code is 5 Swift files. Zero external dependencies.

---

## Security

- Server binds explicitly to `127.0.0.1:8765`; LAN clients cannot connect.
- No authentication in V1; local MCP clients on the same Mac can call tools while the server is running.
- Camera permission remains the primary macOS privacy gate.
- No microphone: audio is not captured.
- Audit log records tool name, timestamp, success/failure, coarse result metadata, and errors only; it does not log output paths, image/video bytes, base64 frames, or full request payloads.
- Audit log path: `~/Library/Logs/Peek/captures.log`

---

## License

MIT
