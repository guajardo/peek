# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

- Production `.app` bundle build script.
- Release verification script.
- Audit logging for tool calls without media bytes or full request payloads.

### Changed

- Clarified installation paths and runtime security guarantees.

### Fixed

- Bound the MCP server explicitly to `127.0.0.1` instead of all interfaces.
- Rejected invalid camera tool arguments before starting camera work.
- Kept the MCP server queue responsive during camera operations.
- Rejected duplicate video recording starts.

### Planned

#### V1.1 — Frame Burst Enhancements
- Frame burst storage with manifest file
- Configurable frame interval/delay

#### V1.5 — Auth + Config UI
- Local token authentication for MCP clients
- Menu bar configuration UI (quality, storage path)
- Auto-start preference on login

#### V2.0 — Video + Stream
- Live stream endpoint (SSE/HTTP streaming)
- Remote binding option with explicit auth
- Video clip trimming

## [1.0.0] - 2026-05-28

### Added

- Menu bar application (LSUIElement, no Dock icon)
- Start/Stop Server control with status display
- MCP over HTTP via NWListener on `127.0.0.1:8765/mcp`
- MCP protocol 2024-11-05 with JSON-RPC transport
- `peek_ping` tool — debug ping with timestamp
- `camera_status` tool — server state + camera permission
- `camera_snapshot` tool — photo capture with quality levels (low/medium/high)
- `camera_start_recording` tool — start video recording, returns recording_id
- `camera_stop_recording` tool — stop recording, returns video_path + duration
- `camera_frames` tool — frame burst capture (1-30 frames, base64 encoded)
- Photo storage to `~/Library/Application Support/Peek/Captures/snapshot_<ts>.jpg`
- Video storage to `~/Library/Application Support/Peek/Captures/video_<ts>.mp4`
- JSONL audit logging to `~/Library/Logs/Peek/captures.log`
- Homebrew formula (`PeekFormula.rb`) for `brew install guajardo/tap/peek`

### Fixed

- MCP Streamable HTTP handshake now accepts `notifications/initialized` with `HTTP 202 Accepted`, negotiates current protocol versions, and buffers HTTP requests until the declared `Content-Length` is available
- MCP tool calls now return valid `CallToolResult` payloads with `content`, `structuredContent`, and `isError`; camera capture delegates are retained until callbacks complete to prevent snapshot timeouts
- One-shot camera captures now stop the `AVCaptureSession` after snapshot or frame burst completion, and `camera_status` reports `camera_active` for live verification
- Camera capture now warms up continuous exposure/white balance before one-shot captures, preventing black snapshots and frame bursts
- Video recording now uses `AVCaptureVideoDataOutput` plus `AVAssetWriter` so recordings finish reliably and use the widest available stream dimensions

### Technical

- Zero external dependencies (Swift stdlib + AVFoundation + Network)
- Headless AVCaptureSession (no preview window)
- Swift Package Manager build: `swift build -c release`
