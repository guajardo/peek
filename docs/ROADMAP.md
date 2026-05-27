# Peek — Implementation Roadmap

> **Source of truth:** [`PEEK-MCP.md`](PEEK-MCP.md) (canonical implementation contract)

---

## Phase 0 — MCP Transport Spike (MANDATORY)

**Goal:** Validate `StatefulHTTPServerTransport` API from `modelcontextprotocol/swift-sdk@0.11.0`.

```
1. SwiftPM project with MCP dependency
2. Single tool: peek_ping → {"ok": true}
3. Start server on 127.0.0.1:8765/mcp
4. Verify with: npx -y @modelcontextprotocol/inspector
5. Confirm:
   - exact endpoint path (/mcp vs /sse)
   - init signature for StatefulHTTPServerTransport
   - server.stop() / transport.close() graceful shutdown
   - ToolList and ToolResult types
   - ListTools handler registration
6. Update PEEK-MCP.md if API differs
```

**Deliverable:** Confirmed SDK API surface. No camera code until this passes.

---

## V1.0 — Snapshot MVP

**Goal:** First downloadable, working release. Only snapshot — no frames, no video.

### What's in scope

```
✅ Menu bar app (LSUIElement, no Dock icon)
✅ Start/Stop MCP server (manual, no auto-start by default)
✅ MCP over HTTP (127.0.0.1:8765)
✅ peek_ping → {"ok": true}
✅ camera_status → JSON metadata
✅ camera_list → JSON device list
✅ camera_snapshot → ImageContent + metadata
✅ Audit logging (JSONL to ~/Library/Logs/Peek/captures.log)
✅ config.json (port, camera defaults, storage)
✅ ~/Library/Logs/Peek/ for logs (NOT Application Support/Logs)
✅ Phase 0 confirmed SDK API
✅ Local-only security (no remote bind, no microphone)
```

### What's NOT in V1.0

```
❌ camera_capture_frames (→ V1.1)
❌ camera_record_video (→ V2.0)
❌ resources/list (→ V1.1 or later)
❌ StoragePruner by size (→ V1.1)
❌ Token auth (→ V1.5)
❌ Configuration UI (→ V1.5)
❌ Live stream (→ V2.0)
```

### V1.0 File Inventory

```
App/
  PeekApp.swift
  PeekAppDelegate.swift
  PeekController.swift
MCP/
  MCPServerManager.swift
  PeekToolRegistry.swift
  PeekToolHandlers.swift
Camera/
  CameraSessionController.swift
  PermissionService.swift
  CameraDeviceProvider.swift
  AVFoundationPhotoCapturer.swift
Storage/
  PeekPaths.swift
  AuditLogger.swift
  SecureImageStore.swift
Config/
  PeekConfig.swift
  ConfigLoader.swift
Models/
  CameraDevice.swift
  CaptureQuality.swift
  CaptureErrors.swift
  CaptureMetadata.swift
Views/
  MenuBarView.swift
docs/
  PEEK-MCP.md ← full implementation contract
  ROADMAP.md ← this file
```

---

## V1.1 — Frame Burst

### New tools
- `camera_capture_frames` — burst of up to 30 frames, returned as ImageContent[] + metadata

### New components
- `FrameBurstCapturer.swift`
- `FrameBurstManifest.swift`
- `CaptureStore` protocol (expanded)
- `resources/list` with frame burst manifests

### Storage additions
- `~/Library/Application Support/Peek/Captures/frames_<ts>_<uuid>/`
- Per-burst `manifest.json`
- Frame files: `frame_001.jpg`, `frame_002.jpg`, etc.

### Pruning additions
- Age-based pruning on startup (by `manifest.json` creation date)
- Optional: size-based pruning (recomputes total after each delete)

---

## V1.5 — Auth + Config UI

### New features
- Local token authentication (Bearer token in Authorization header)
- Menu bar configuration panel
- Auto-start toggle
- Camera device selector
- Quality preset selector

### Config additions
- `security.require_local_token: true`
- `security.token: "<generated>"`

### Changes
- `server.json` gains `auth_enabled: true` and `token: "<redacted>"`
- Tool handlers validate Bearer token on every call

---

## V2.0 — Video + Stream

### New tools
- `camera_record_video` — MP4 without audio, returns resource URI + metadata

### New components
- `VideoCapturer.swift`
- `StoragePruner` full implementation (age + size, recursive)

### Video storage
- `~/Library/Application Support/Peek/Captures/video_<ts>_<uuid>.mp4`

### Optional
- Live stream endpoint
- Remote binding (with explicit auth, off by default)

---

## Version Mapping

| File Section | Phase | Status |
|-------------|-------|--------|
| §2 Architecture (layered design, component map) | All | ✅ |
| §3 Storage & Paths | V1.0 | ✅ |
| §4 Configuration (config.json) | V1.0 | ✅ |
| §5 MCP Server Design | V1.0 | ✅ |
| §6 Tools V1 (status, list, snapshot) | V1.0 | ✅ |
| §6 Tools (frames) | V1.1 | 🔜 |
| §6 Tools (video) | V2.0 | 🔜 |
| §7 Menu Bar UI | V1.0 | ✅ |
| §8 Privacy & Security | V1.0 | ✅ |
| §9 Implementation Components | V1.0 | ✅ |
| §10 Phase 0 spike | **Mandatory** | ⚠️ |
| §11 Refactoring Plan | Post-V1.0 | 📋 |

---

## Key Spec Decisions Preserved

These decisions are locked and not revisited:

| Decision | Rationale |
|----------|-----------|
| No Hermes references in code | Standalone open source |
| 127.0.0.1 only binding | Local-only security model |
| No microphone in V1 | Minimal attack surface |
| Manual start default | User consent model |
| Menu bar icon | Always-visible server status |
| JSONL audit log | Accountability + debugging |
| Phase 0 mandatory | SDK API unconfirmed |
| server.json with token=null | Explicit about V1 auth state |