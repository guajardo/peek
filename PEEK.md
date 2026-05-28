# Peek — V1 Source of Truth

> **Goal:** Minimal, fast, shipped. No features beyond V1 scope.

## What It Is

Menu bar macOS app that exposes webcam as MCP server. Any MCP client connects via `http://127.0.0.1:8765/mcp` and calls tools.

**V1 ships:** photos, video, frame bursts. That's it.

---

## UI (Menu Bar)

```
📷 Status: Connected ●   ← menu bar icon (camera)
  ├─ Server: Running on :8765
  ├─ [Stop Server]
  ├─ ─────────────────
  └─ [Quit Peek]
```

When stopped:
```
📷 Status: Stopped ○
  ├─ [Start Server]
  ├─ ─────────────────
  └─ [Quit Peek]
```

- No Dock icon (`LSUIElement = true`)
- Two states: Connected / Stopped
- Single icon, no submenu nesting

---

## MCP Server

- **Transport:** Swift HTTP server using `NWListener` from Network framework
- **Endpoint:** `http://127.0.0.1:8765/mcp`
- **Binding:** 127.0.0.1 only (local-only, no remote)
- **Spec:** MCP 2024-11-05 (JSON-RPC over HTTP)

### Tools

#### `peek_ping`
```json
{"name": "peek_ping", "description": "Debug ping"}
→ {"ok": true, "timestamp": "..."}
```

#### `camera_status`
```json
{"name": "camera_status", "description": "Camera service state"}
→ {"ok": true, "server_running": true, "camera_permission": "granted|denied|undetermined"}
```

#### `camera_snapshot`
```json
{"name": "camera_snapshot", "description": "Take a photo",
 "inputSchema": {
   "type": "object",
   "properties": {
     "quality": {"type": "string", "enum": ["low", "medium", "high"], "default": "medium"}
   }
 }}
→ {"ok": true, "image_path": "~/Library/Application Support/Peek/Captures/snapshot_<ts>.jpg", "width": 1920, "height": 1080}
```

#### `camera_start_recording`
```json
{"name": "camera_start_recording", "description": "Start video recording"}
→ {"ok": true, "recording_id": "uuid", "started_at": "..."}
```

#### `camera_stop_recording`
```json
{"name": "camera_stop_recording", "description": "Stop video recording",
 "inputSchema": {
   "type": "object",
   "properties": {
     "recording_id": {"type": "string"}
   }
 }}
→ {"ok": true, "video_path": "~/Library/Application Support/Peek/Captures/video_<ts>.mp4", "duration_seconds": 5.2}
```

#### `camera_frames`
```json
{"name": "camera_frames", "description": "Capture frame burst",
 "inputSchema": {
   "type": "object",
   "properties": {
     "count": {"type": "number", "minimum": 1, "maximum": 30, "default": 10},
     "quality": {"type": "string", "enum": ["low", "medium", "high"], "default": "medium"}
   }
 }}
→ {"ok": true, "frames": ["base64_jpeg...", ...], "count": 10}
```

---

## File Structure

```
Peek/
├── Sources/
│   └── Peek/
│       ├── main.swift              # @main entry point
│       ├── PeekApp.swift           # Menu bar UI (SwiftUI)
│       ├── MCPServer.swift         # HTTP server + tool handlers
│       └── Camera.swift            # AVCaptureSession wrapper
├── Resources/
│   ├── Info.plist
│   ├── Peek.entitlements
│   └── Assets.xcassets/
├── Package.swift
├── PeekFormula.rb                  # Homebrew formula
└── PEEK.md                        # This file
```

---

## Camera Session Rules

1. One `AVCaptureSession` owned by `Camera` class
2. Session started once on `camera_start_recording`, stopped on `camera_stop_recording`
3. For snapshots: start session → capture → stop session (no preview)
4. No preview window — headless operation
5. `camera_permission` checked on first use via `AVCaptureDevice.requestAccess`

---

## Storage

```
~/Library/Application Support/Peek/
├── config.json                     # {"server": {"port": 8765}}
└── Captures/
    ├── snapshot_<ts>.jpg          # Photos saved to disk
    └── video_<ts>.mp4              # Videos saved to disk

~/Library/Logs/Peek/
└── captures.log                    # JSONL: {"ts":"...","tool":"...","ok":true}
```

All captures saved to `~/Library/Application Support/Peek/Captures/`.

---

## Error Handling

```swift
enum PeekError: Error {
    case cameraNotAvailable
    case permissionDenied
    case cameraBusy
    case encodingFailed
    case invalidRecordingID
}
```

All tools return `{"ok": false, "error": "description"}` on failure.

---

## Dependencies

- **No external dependencies.**
- Swift standard library + AVFoundation + Network (NWListener)
- No SPM packages, no CocoaPods, no Homebrew deps

Build with:
```bash
swift build -c release
```

---

## Homebrew Install

```bash
brew install guajardo/tap/peek
```

Formula (`PeekFormula.rb`):
```ruby
class Peek < Formula
  desc "MCP webcam server for macOS"
  homepage "https://github.com/guajardo/peek"
  url "https://github.com/guajardo/peek.git"
  version "1.0.0"

  depends_on :macos => :big_sur

  def install
    system "swift", "build", "-c", "release"
    bin.install ".build/release/Peek"
  end
end
```

After install:
```bash
open -a Peek   # launches menu bar app
```

---

## MCP Client Config

Claude Desktop (`~/.claude.json`):
```json
{
  "mcpServers": {
    "peek": {
      "url": "http://127.0.0.1:8765/mcp"
    }
  }
}
```

---

## Info.plist Keys

```xml
<key>LSUIElement</key><true/>
<key>NSCameraUsageDescription</key><string>Peek needs camera access to capture photos and video when requested by an MCP client.</string>
```

## Entitlements

```xml
<key>com.apple.security.device.camera</key><true/>
```

Sandbox: OFF (camera access + file writes incompatible with sandbox)

---

## V1 Scope (Final)

### IN
- Menu bar app (LSUIElement)
- Start/Stop server
- Connected/Stopped status
- `peek_ping`, `camera_status`, `camera_snapshot`
- `camera_start_recording`, `camera_stop_recording`
- `camera_frames`
- Photo storage on disk
- Video storage on disk
- Homebrew install

### NOT IN (V2+)
- Token/auth
- Config UI
- Live preview
- Auto-start
- Storage pruning
- Multiple cameras selector
