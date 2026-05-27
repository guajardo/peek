# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Initial project structure
- Menu bar application with start/stop server control
- MCP over HTTP on 127.0.0.1:8765
- `peek_ping` tool for MCP transport debugging
- `camera_status` tool
- `camera_list` tool
- `camera_snapshot` tool (V1 MVP: single photo capture)
- Audit logging to `~/Library/Logs/Peek/captures.log`
- JSON configuration via `~/Library/Application Support/Peek/config.json`

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