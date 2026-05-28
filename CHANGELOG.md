# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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

### Technical
- Zero external dependencies (Swift stdlib + AVFoundation + Network)
- Headless AVCaptureSession (no preview window)
- Swift Package Manager build: `swift build -c release`

## [Unreleased]

### Fixed
- MCP Streamable HTTP handshake now accepts `notifications/initialized` with `HTTP 202 Accepted`, negotiates current protocol versions, and buffers HTTP requests until the declared `Content-Length` is available.
- MCP tool calls now return valid `CallToolResult` payloads with `content`, `structuredContent`, and `isError`; camera capture delegates are retained until callbacks complete to prevent snapshot timeouts.
- One-shot camera captures now stop the `AVCaptureSession` after snapshot or frame burst completion, and `camera_status` reports `camera_active` for live verification.
- Camera capture now warms up continuous exposure/white balance before one-shot captures, preventing black snapshots and frame bursts; video recording now uses `AVCaptureVideoDataOutput` plus `AVAssetWriter` so recordings finish reliably and use the widest available stream dimensions exposed by the camera output.

### Planned

#### V1.1 — Frame Burst
- `camera_capture_frames` (up to 30 frames, ImageContent[])
- Frame burst storage with manifest

#### V1.5 — Auth + Config UI
- Local token authentication
- Menu bar configuration UI
- Auto-start preference

#### V2.0 — Video + Stream
- `camera_record_video` (MP4 without audio)
- Live stream endpoint
- Remote binding with explicit auth
