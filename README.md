# Peek — MCP Webcam Server

> **V1.0** — Photos, video, frame bursts. Nothing more.

---

## What is Peek?

Menu bar macOS app that exposes your webcam as an MCP server. Any MCP client (Claude, Codex, Cursor, Hermes Agent) connects to `http://127.0.0.1:8765/mcp` and calls tools to capture photos, video, and frame bursts.

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

---

## Install

### Homebrew (recommended for users)

```bash
brew install guajardo/tap/peek
Peek --start-server
```

### Build from source (for development)

```bash
git clone https://github.com/guajardo/peek.git
cd peek
scripts/build_app_bundle.sh
open dist/Peek.app
```

---

## Configure MCP Client

**Hermes Agent** (already configured — just start Peek):

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

**Other MCP clients:** Same endpoint — `http://127.0.0.1:8765/mcp`

---

## Usage

1. Open Peek — camera icon appears in menu bar
2. Click **Start Server**
3. Grant camera permission when prompted
4. MCP client connects and can call tools

## Tool Behavior

- `camera_snapshot` and `camera_frames` accept `quality` values of `low`, `medium`, or `high`.
- Quality maps to the requested AVFoundation session preset. The actual dimensions still depend on the camera and macOS capture format; on the current verification machine, both `low` and `high` snapshots returned `1920x1080`.
- Invalid `quality` values and invalid frame counts are rejected before camera work starts.

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
├── AGENTS.md              # AI agent guidelines
├── CHANGELOG.md
└── README.md
```

5 Swift files. Zero external dependencies.

---

## Security

- **Local binding only**: 127.0.0.1 — no remote access
- **Manual start**: Server off by default
- **Camera permission**: macOS permission prompt is the gate
- **No microphone**: Audio not captured
- **Audit log**: All tool calls logged to `~/Library/Logs/Peek/captures.log`

---

## License

MIT
