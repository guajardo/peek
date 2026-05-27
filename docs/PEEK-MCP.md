# Peek — MCP Webcam Server

> **Status:** Implementation Contract (V2.1.2)  
> **Version:** 1.1  
> **Name:** Peek  
> **Last Updated:** May 27, 2026  
> **Spec:** MCP 2025-11-25 | Swift 6.0+ | macOS 14.0+

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Storage & Paths](#3-storage--paths)
4. [Configuration](#4-configuration)
5. [MCP Server Design](#5-mcp-server-design)
6. [Tools V1](#6-tools-v1)
7. [Menu Bar UI](#7-menu-bar-ui)
8. [Privacy & Security Model](#8-privacy--security-model)
9. [Implementation Components](#9-implementation-components)
10. [Implementation Phases](#10-implementation-phases)
11. [Refactoring Plan](#11-refactoring-plan)
12. [Build & Run](#12-build--run)
13. [Testing Matrix](#13-testing-matrix)
14. [Appendix A: Config Schema](#appendix-a-config-schema)
15. [Appendix B: Info.plist & Entitlements](#appendix-b-infoplist--entitlements)
16. [Appendix C: Naming & Structure Rules](#appendix-c-naming--structure-rules)

---

## 1. Overview

**Peek** is a standalone macOS menu bar application that operates as an MCP server, giving any MCP-compatible client (Claude, Codex, Cursor, Hermes Agent, etc.) direct access to the webcam for photos, frame bursts, and video clips.

### Core Principles

| Principle | Description |
|-----------|-------------|
| **Standalone** | No dependency on Hermes, `.hermes/`, or any agent framework. Runs independently. |
| **Menu bar first** | Visible status indicator (●), start/stop control, port display. User is always aware when the server is alive. |
| **MCP native** | Implements MCP 2025-11-25 spec via `modelcontextprotocol/swift-sdk`. HTTP transport on `127.0.0.1`. |
| **User-controlled** | Manual server start by default. Auto-start is a configurable preference, not default. |
| **Minimal attack surface** | No microphone in V1. No remote binding. macOS camera permission is the only gate. |
| **Audit trail** | Every tool call is logged to `captures.log` as JSONL with timestamp, tool name, and outcome. |

### V1 Feature Matrix

| Feature | Status | Notes |
|---------|--------|-------|
| Menu bar app (LSUIElement) | ✅ | No Dock icon |
| Start/Stop MCP server | ✅ | Manual only, auto-start optional |
| MCP over HTTP (127.0.0.1) | ✅ | Port 8765 default |
| `camera_status` | ✅ | JSON metadata response |
| `camera_list` | ✅ | JSON metadata response |
| `camera_snapshot` | ✅ | ImageContent + metadata text |
| `camera_capture_frames` | ✅ | Max 30 frames, ImageContent[] + metadata |
| `camera_record_video` | ✅ | MP4 without audio, returned as resource URI |
| Configuration via JSON | ✅ | `~/Library/Application Support/Peek/config.json` |
| Audit logging (JSONL) | ✅ | Every tool call logged |
| Live stream | ❌ | V2 |
| Configuration UI | ❌ | V2 |
| Microphone / audio | ❌ | Not V1 |
| Auth token | ❌ | V1.5 |

---

## 2. Architecture

### 2.1 Layered Design

```
MCP Protocol Layer          PeekMCPServer
                            ↓
Tool Registry               PeekToolRegistry (tools/list response)
                            ↓
Tool Handling               PeekToolHandlers
                            ↓
Camera Coordinator          CameraSessionController (actor, sole owner)
                            ↓
Concrete Capture            AVFoundationPhotoCapturer
                            FrameBurstCapturer
                            VideoCapturer
                            ↓
Storage / Audit             AuditLogger, SecureImageStore, PeekPaths
```

**Rule:** No tool handler may instantiate `CameraSessionController`, `CameraCaptureService`, or any capturer directly. All capture operations route through the single `CameraSessionController` owned by `MCPServerManager`.

### 2.2 Component Map

```
Sources/Peek/
├── App/
│   ├── PeekApp.swift              # Entry point, @main
│   ├── PeekAppDelegate.swift      # NSApplicationDelegate
│   └── PeekController.swift       # @MainActor bridge: UI ↔ serverManager
├── MCP/
│   ├── MCPServerManager.swift     # Actor: HTTP server lifecycle, owns CSC + AuditLogger
│   ├── PeekToolRegistry.swift     # tools/list implementation
│   ├── PeekToolHandlers.swift     # All tool handlers (call_tool)
│   └── PeekResources.swift        # resources/list implementation
├── Camera/
│   ├── CameraSessionController.swift  # Actor: serializes camera ops, busy policy
│   ├── PermissionService.swift        # macOS camera permission
│   ├── CameraDeviceProvider.swift    # Static device enumeration
│   ├── AVFoundationPhotoCapturer.swift # Low-level photo capture
│   ├── FrameBurstCapturer.swift        # Frame burst capture
│   └── VideoCapturer.swift             # MP4 video capture (no audio)
├── Storage/
│   ├── PeekPaths.swift           # All path constants
│   ├── CaptureStore.swift        # Protocol: writeJPEG, writeFrameJPEG, writeManifest
│   ├── SecureImageStore.swift    # Atomic JPEG writes
│   ├── StoragePruner.swift       # Prune old captures on startup
│   ├── AuditLogger.swift         # Actor: JSONL file append via FileHandle
│   └── ServerInfoStore.swift     # server.json: write, read, delete, stale-cleanup
├── Config/
│   ├── PeekConfig.swift          # All config structs
│   └── ConfigLoader.swift        # load() / save() with snake_case support
├── Models/
│   ├── CameraDevice.swift
│   ├── CaptureQuality.swift
│   ├── CaptureErrors.swift
│   └── CaptureMetadata.swift     # Tool response metadata structs
└── Views/
    └── MenuBarView.swift
```

### 2.3 Data Flow

```
┌─────────────────────┐   HTTP/MCP     ┌──────────────────────┐
│ MCP Client          │ ←─────────────│ Peek.app              │
│ (Claude, Codex,     │               │                        │
│  Hermes Agent, etc) │               │ PeekMCPServer          │
└─────────────────────┘               │   ↓                    │
                                       │ PeekToolHandlers      │
                                       │   ↓                    │
                                       │ CameraSessionController (ACTOR)
                                       │   ↓                    │
                                       │ AVFoundation*Capturers│
                                       └──────────────────────┘
                                           ↓
                                       AuditLogger + SecureImageStore
```

### 2.4 Naming Rule

**No class, struct, enum, or file may contain "Hermes", "HermesCamera", or any reference to Hermes framework.** Peek must be fully standalone and self-contained.

### 2.5 Server Lifecycle

```
1. App launches → menu bar icon appears (LSUIElement = true)
2. PeekAppDelegate.applicationDidFinishLaunching
   - PeekController.loadConfig() → PeekConfig
   - If config.app.autoStart → startServer()
   - Else → AppState = idle
3. User clicks "Start Server"
   → MCPServerManager.start(config, paths)
   → MCPServerManager creates CameraSessionController (shared, unique)
   → MCPServerManager creates AuditLogger (shared, unique)
   → HTTP server listening on 127.0.0.1:<port>/mcp
   → server.json written (pid, port, endpoint, token=null, auth_enabled=false)
4. MCP clients connect
5. User clicks "Stop Server" or Quit
   → AuditLogger.close()
   → MCPServerManager.stop() (graceful shutdown)
   → server.json deleted
```

---

## 3. Storage & Paths

### 3.1 Directory Structure

```
~/Library/Application Support/Peek/
├── config.json                    # User configuration
├── server.json                    # Runtime state (pid, port, endpoint, token, auth_enabled)
└── Captures/
    ├── snapshot_<ts>_<uuid>.jpg
    ├── video_<ts>_<uuid>.mp4
    └── frames_<ts>_<uuid>/
        ├── frame_001.jpg
        ├── manifest.json

~/Library/Caches/Peek/             # Temp files, pruneable
~/Library/Logs/Peek/
    ├── startup.log
    ├── errors.log
    └── captures.log                # JSONL audit log

All directories: mode 0o700.
```

**Critical path correction:** Logs go to `~/Library/Logs/Peek/`, NOT `~/Library/Application Support/Peek/Logs/`.

### 3.2 PeekPaths.swift

```swift
import Foundation

public struct PeekPaths: Sendable {
    public let appSupport: URL
    public let cache: URL
    public let logs: URL
    public let captures: URL

    public init() {
        let fm = FileManager.default

        let appSupportBase = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.appSupport = appSupportBase.appendingPathComponent("Peek", isDirectory: true)

        let cachesBase = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cache = cachesBase.appendingPathComponent("Peek", isDirectory: true)

        // CORRECT: ~/Library/Logs/Peek/, not appSupport/Logs/Peek
        let libraryBase = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        self.logs = libraryBase
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Peek", isDirectory: true)

        self.captures = appSupport.appendingPathComponent("Captures", isDirectory: true)
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        let mode = NSNumber(value: 0o700)
        for dir in [appSupport, cache, logs, captures] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
            }
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: dir.path)
        }
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    public func snapshotPath() throws -> URL {
        let ts = timestamp()
        let uuid = UUID().uuidString.prefix(8)
        return captures.appendingPathComponent("snapshot_\(ts)_\(uuid).jpg")
    }

    public func videoPath() throws -> URL {
        let ts = timestamp()
        let uuid = UUID().uuidString.prefix(8)
        return captures.appendingPathComponent("video_\(ts)_\(uuid).mp4")
    }

    public func framesDirectory() throws -> URL {
        let ts = timestamp()
        let uuid = UUID().uuidString.prefix(8)
        let dir = captures.appendingPathComponent("frames_\(ts)_\(uuid)", isDirectory: true)
        // ALSO set permissions on frames directory to 0700
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return dir
    }

    public var configPath: URL { appSupport.appendingPathComponent("config.json") }
    public var serverInfoPath: URL { appSupport.appendingPathComponent("server.json") }
    public var capturesLogPath: URL { logs.appendingPathComponent("captures.log") }
    public var startupLogPath: URL { logs.appendingPathComponent("startup.log") }
    public var errorsLogPath: URL { logs.appendingPathComponent("errors.log") }
}
```

---

## 4. Configuration

### 4.1 config.json Schema

```json
{
  "app": {
    "name": "Peek",
    "auto_start": false
  },
  "server": {
    "host": "127.0.0.1",
    "port": 8765
  },
  "camera": {
    "default_device_id": null,
    "default_quality": "medium"
  },
  "photo": {
    "width": 1920,
    "height": 1080,
    "quality": 85
  },
  "frame": {
    "width": 1920,
    "height": 1080,
    "quality": 75,
    "count": 10,
    "fps": 30
  },
  "video": {
    "width": 1280,
    "height": 720,
    "quality": 75,
    "min_duration_seconds": 3,
    "max_duration_seconds": 60,
    "fps": 30
  },
  "storage": {
    "max_total_size_mb": 2048,
    "max_capture_age_days": 7,
    "prune_on_start": true
  },
  "security": {
    "require_local_token": false
  }
}
```

**Note:** `allow_remote_bind` is NOT in V1 config. V1 always binds to 127.0.0.1 regardless of any config setting.

### 4.2 PeekConfig.swift

```swift
import Foundation

public struct PeekConfig: Codable, Sendable {
    public var app: AppConfig
    public var server: ServerConfig
    public var camera: CameraConfig
    public var photo: PhotoConfig
    public var frame: FrameConfig
    public var video: VideoConfig
    public var storage: StorageConfig
    public var security: SecurityConfig

    public struct AppConfig: Codable, Sendable {
        public var name: String = "Peek"
        public var autoStart: Bool = false
        enum CodingKeys: String, CodingKey {
            case name
            case autoStart = "auto_start"
        }
    }

    public struct ServerConfig: Codable, Sendable {
        public var host: String = "127.0.0.1"
        public var port: Int = 8765
    }

    public struct CameraConfig: Codable, Sendable {
        public var defaultDeviceId: String? = nil
        public var defaultQuality: String = "medium"
        enum CodingKeys: String, CodingKey {
            case defaultDeviceId = "default_device_id"
            case defaultQuality = "default_quality"
        }
    }

    public struct PhotoConfig: Codable, Sendable {
        public var width: Int = 1920
        public var height: Int = 1080
        public var quality: Int = 85
    }

    public struct FrameConfig: Codable, Sendable {
        public var width: Int = 1920
        public var height: Int = 1080
        public var quality: Int = 75
        public var count: Int = 10
        public var fps: Int = 30
    }

    public struct VideoConfig: Codable, Sendable {
        public var width: Int = 1280
        public var height: Int = 720
        public var quality: Int = 75
        public var minDurationSeconds: Int = 3
        public var maxDurationSeconds: Int = 60
        public var fps: Int = 30
        enum CodingKeys: String, CodingKey {
            case width, height, quality, fps
            case minDurationSeconds = "min_duration_seconds"
            case maxDurationSeconds = "max_duration_seconds"
        }
    }

    public struct StorageConfig: Codable, Sendable {
        public var maxTotalSizeMB: Int = 2048
        public var maxCaptureAgeDays: Int = 7
        public var pruneOnStart: Bool = true
        enum CodingKeys: String, CodingKey {
            case maxTotalSizeMB = "max_total_size_mb"
            case maxCaptureAgeDays = "max_capture_age_days"
            case pruneOnStart = "prune_on_start"
        }
    }

    public struct SecurityConfig: Codable, Sendable {
        public var requireLocalToken: Bool = false
        enum CodingKeys: String, CodingKey {
            case requireLocalToken = "require_local_token"
        }
    }

    public init(
        app: AppConfig = AppConfig(),
        server: ServerConfig = ServerConfig(),
        camera: CameraConfig = CameraConfig(),
        photo: PhotoConfig = PhotoConfig(),
        frame: FrameConfig = FrameConfig(),
        video: VideoConfig = VideoConfig(),
        storage: StorageConfig = StorageConfig(),
        security: SecurityConfig = SecurityConfig()
    ) {
        self.app = app
        self.server = server
        self.camera = camera
        self.photo = photo
        self.frame = frame
        self.video = video
        self.storage = storage
        self.security = security
    }
}
```

### 4.3 ConfigLoader

```swift
public enum ConfigLoadResult: Sendable {
    case loaded(PeekConfig)
    case createdDefault(PeekConfig)
    case invalid(error: String, fallback: PeekConfig)
}

public final class ConfigLoader: Sendable {
    private let paths: PeekPaths

    public init(paths: PeekPaths = PeekPaths()) {
        self.paths = paths
    }

    public func load() -> ConfigLoadResult {
        let path = paths.configPath

        guard FileManager.default.fileExists(atPath: path.path) else {
            let defaultConfig = PeekConfig()
            // MUST write default to disk so user can edit it
            try? save(defaultConfig)
            return .createdDefault(defaultConfig)
        }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let config = try decoder.decode(PeekConfig.self, from: data)
            return .loaded(config)
        } catch {
            let fallback = PeekConfig()
            return .invalid(error: error.localizedDescription, fallback: fallback)
        }
    }

    public func save(_ config: PeekConfig) throws {
        try paths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(config)
        try data.write(to: paths.configPath, options: .atomic)
    }
}
```

---

## 5. MCP Server Design

### 5.1 Transport

- **Transport:** `StatefulHTTPServerTransport` from `modelcontextprotocol/swift-sdk@0.11.0`
- **Endpoint:** `http://127.0.0.1:<port>/mcp`
- **Binding:** `127.0.0.1` only. V1 MUST NOT bind to `0.0.0.0`.
- **Spec:** MCP 2025-11-25

> **⚠️ Phase 0 spike REQUIRED before implementing camera tools.** Create a minimal PeekMCPServer with single tool `peek_ping` → `{"ok": true}`. Start `StatefulHTTPServerTransport` on `127.0.0.1:8765/mcp`. Verify with MCP Inspector. Confirm exact SDK API (endpoint path, init signature, graceful shutdown API). Update this contract if API differs before proceeding to camera implementation.

### 5.2 MCPServerManager

```swift
import MCP
import Foundation
import Network

public actor MCPServerManager {
    public enum ServerState: Sendable {
        case idle
        case starting
        case running(port: Int)
        case stopping
        case error(String)
    }

    private let paths: PeekPaths
    private let config: PeekConfig  // Set once after loadConfig()
    private var server: Server?
    private var transport: StatefulHTTPServerTransport?
    private var listenerTask: Task<Void, Never>?

    // Single shared instances (created in init or start)
    private let cameraController: CameraSessionController
    private let auditLogger: AuditLogger

    public private(set) var state: ServerState = .idle

    public init(
        paths: PeekPaths = PeekPaths(),
        config: PeekConfig = PeekConfig(),
        cameraController: CameraSessionController? = nil,
        auditLogger: AuditLogger? = nil
    ) {
        self.paths = paths
        self.config = config
        self.cameraController = cameraController ?? CameraSessionController()
        self.auditLogger = auditLogger ?? AuditLogger(paths: paths)
    }

    public func start() async throws -> Int {
        guard case .idle = state else {
            throw PeekError.serverAlreadyRunning
        }
        state = .starting

        try paths.ensureDirectories()
        try await auditLogger.start()  // Open FileHandle

        let port = try findAvailablePort(startingFrom: config.server.port)
        let host = config.server.host
        let endpoint = URL(string: "http://\(host):\(port)/mcp")!

        // Build MCP server
        let server = Server(
            name: "Peek",
            version: "1.0.0",
            capabilities: .init(
                tools: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false)
            )
        )

        // REQUIRED: ListTools handler for client discovery
        await server.withMethodHandler(ListTools.self) { _ in
            PeekToolRegistry.listTools()
        }

        // CallTool handler — passes shared cameraController + auditLogger
        await server.withMethodHandler(CallTool.self) { [self] params in
            await PeekToolHandlers.handle(
                params: params,
                config: config,
                paths: paths,
                cameraController: cameraController,
                auditLogger: auditLogger
            )
        }

        // Resources list handler
        await server.withMethodHandler(ListResources.self) { [self] params in
            PeekResources.list(paths: paths)
        }

        let transport = StatefulHTTPServerTransport(endpoint: endpoint, server: server)
        self.transport = transport
        self.server = server

        // Write server info BEFORE starting
        try ServerInfoStore.write(port: port, host: host)

        listenerTask = Task {
            do {
                try await server.start(transport: transport)
            } catch {
                await handleError(String(describing: error))
            }
        }

        // Grace period for server to start listening
        // ⚠️ If SDK start API is blocking, this 100ms grace period is acceptable only after Phase 0
        // confirms no better readiness signal exists. Preferred: write server.json only after
        // transport readiness is confirmed.
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        state = .running(port: port)
        return port
    }

    public func stop() async {
        guard case .running = state else { return }
        state = .stopping

        // Graceful shutdown via SDK
        if let server = self.server {
            try? await server.stop()
        }
        if let transport = self.transport {
            try? await transport.close()
        }

        listenerTask?.cancel()
        listenerTask = nil
        self.server = nil
        self.transport = nil

        await auditLogger.close()
        try? ServerInfoStore.delete()

        state = .idle
    }

    private func findAvailablePort(startingFrom port: Int) throws -> Int {
        for offset in 0..<10 {
            let candidate = port + offset
            let parameters = NWParameters.tcp
            let nwPort = NWEndpoint.Port(rawValue: UInt16(candidate))!
            let listener = try? NWListener(using: parameters, on: nwPort)
            if listener != nil {
                listener?.cancel()
                return candidate
            }
        }
        throw PeekError.noAvailablePort
    }

    private func handleError(_ msg: String) async {
        try? ServerInfoStore.delete()
        state = .error(msg)
    }
}

public enum PeekError: Error, LocalizedError {
    case noAvailablePort
    case serverAlreadyRunning
    case serverNotRunning

    public var errorDescription: String? {
        switch self {
        case .noAvailablePort: return "No available port in range"
        case .serverAlreadyRunning: return "Server already running"
        case .serverNotRunning: return "Server not running"
        }
    }
}
```

### 5.3 server.json Format (V1)

```json
{
  "pid": 12345,
  "port": 8765,
  "host": "127.0.0.1",
  "endpoint": "http://127.0.0.1:8765/mcp",
  "token": null,
  "auth_enabled": false,
  "started_at": "2026-05-27T12:30:45Z"
}
```

- `token: null` and `auth_enabled: false` make explicit that V1 has no authentication.
- `pid` enables detection of stale server.json on next launch.

### 5.4 Startup Staleness Check

On app launch, before starting server:
1. Read `server.json` if it exists
2. Check if `pid` process is still running
3. If not running, delete stale `server.json`
4. Proceed normally

This prevents false "server already running" claims after forced shutdown.

---

## 6. Tools V1

### 6.1 Tool Discovery — PeekToolRegistry

```swift
public struct PeekToolRegistry {
    public static func listTools() -> ToolList {
        ToolList(tools: [
            Tool(
                name: "camera_status",
                description: "Returns current camera service state and macOS camera permission status.",
                inputSchema: .init(
                    type: "object",
                    properties: [:],
                    additionalProperties: false
                )
            ),
            Tool(
                name: "camera_list",
                description: "Lists all available cameras with name and unique identifier.",
                inputSchema: .init(
                    type: "object",
                    properties: [:],
                    additionalProperties: false
                )
            ),
            Tool(
                name: "camera_snapshot",
                description: "Captures a single high-resolution photo from the webcam.",
                inputSchema: .init(
                    type: "object",
                    properties: [
                        "quality": .init(
                            type: "string",
                            enum: ["low", "medium", "high"],
                            default: "medium"
                        ),
                        "device_id": .init(
                            type: "string",
                            description: "Optional device identifier. Uses config default if omitted."
                        )
                    ],
                    additionalProperties: false
                )
            ),
            Tool(
                name: "camera_capture_frames",
                description: "Captures a burst of frames from the webcam.",
                inputSchema: .init(
                    type: "object",
                    properties: [
                        "count": .init(
                            type: "integer",
                            minimum: 1,
                            maximum: 30,
                            default: 10
                        ),
                        "fps": .init(
                            type: "integer",
                            minimum: 1,
                            maximum: 30,
                            default: 30
                        ),
                        "quality": .init(
                            type: "string",
                            enum: ["low", "medium", "high"],
                            default: "medium"
                        ),
                        "device_id": .init(
                            type: "string",
                            description: "Optional camera device identifier."
                        )
                    ],
                    additionalProperties: false
                )
            ),
            Tool(
                name: "camera_record_video",
                description: "Records a video clip (MP4 without audio) and returns it as a resource URI.",
                inputSchema: .init(
                    type: "object",
                    properties: [
                        "duration_seconds": .init(
                            type: "number",
                            minimum: 3,
                            maximum: 60,
                            default: 5.0
                        ),
                        "device_id": .init(
                            type: "string",
                            description: "Optional camera device identifier."
                        )
                    ],
                    additionalProperties: false
                )
            )
        ])
    }
}
```

> **Note:** The `ToolInputSchema.Property` usage above is illustrative of the JSON schema structure. After Phase 0 spike validates the actual Swift SDK API, the exact syntax for schemas must be adapted to match the SDK's `Tool` initializer.

### 6.2 Tool Call Handler — PeekToolHandlers

```swift
public struct PeekToolHandlers {
    public static func handle(
        params: CallTool.Params,
        config: PeekConfig,
        paths: PeekPaths,
        cameraController: CameraSessionController,
        auditLogger: AuditLogger
    ) async -> ToolResult {
        let started = Date()
        let toolName = params.name

        let result = await handleInner(
            params: params,
            config: config,
            paths: paths,
            cameraController: cameraController
        )

        let durationMs = Int(Date().timeIntervalSince(started) * 1000)

        await auditLogger.log(tool: toolName, ok: !result.isError, durationMs: durationMs)

        return result
    }

    private static func handleInner(
        params: CallTool.Params,
        config: PeekConfig,
        paths: PeekPaths,
        cameraController: CameraSessionController
    ) async -> ToolResult {
        switch params.name {
        case "camera_status":
            return await cameraStatus(config: config)

        case "camera_list":
            return await cameraList(config: config)

        case "camera_snapshot":
            return await cameraSnapshot(params: params, config: config, paths: paths, cameraController: cameraController)

        case "camera_capture_frames":
            return await cameraCaptureFrames(params: params, config: config, paths: paths, cameraController: cameraController)

        case "camera_record_video":
            return await cameraRecordVideo(params: params, config: config, paths: paths, cameraController: cameraController)

        default:
            return ToolResult(content: [.text("{\"ok\": false, \"error\": \"Unknown tool: \(params.name)\"}")], isError: true)
        }
    }

    // MARK: - camera_status

    private static func cameraStatus(config: PeekConfig) async -> ToolResult {
        let permission = PermissionService.shared.cameraAuthorizationStatus()
        let metadata: [String: Any] = [
            "ok": true,
            "service_state": "running",
            "camera_permission": permission,
            "config_default_device_id": config.camera.defaultDeviceId ?? NSNull(),
            "config_default_quality": config.camera.defaultQuality
        ]
        return ToolResult(content: [.text(compactJSON(metadata))])
    }

    // MARK: - camera_list

    private static func cameraList(config: PeekConfig) async -> ToolResult {
        let devices = CameraDeviceProvider.availableDevices()
        let metadata: [String: Any] = [
            "ok": true,
            "count": devices.count,
            "devices": devices.map { d in
                ["id": d.id, "name": d.name, "is_default": d.isDefault]
            }
        ]
        return ToolResult(content: [.text(compactJSON(metadata))])
    }

    // MARK: - camera_snapshot

    private static func cameraSnapshot(
        params: CallTool.Params,
        config: PeekConfig,
        paths: PeekPaths,
        cameraController: CameraSessionController
    ) async -> ToolResult {
        let qualityArg = params.arguments?["quality"]?.stringValue ?? config.camera.defaultQuality
        let deviceID = params.arguments?["device_id"]?.stringValue ?? config.camera.defaultDeviceId

        let quality = CaptureQuality(rawValue: qualityArg) ?? .medium

        let result = await cameraController.snapshot(
            deviceID: deviceID,
            quality: quality,
            photoConfig: config.photo,
            paths: paths
        )

        switch result {
        case .success(let url):
            guard let imageData = try? Data(contentsOf: url) else {
                return ToolResult(content: [.text("{\"ok\": false, \"error\": \"could not read image\"}")], isError: true)
            }
            let metadata: [String: Any] = [
                "ok": true,
                "type": "photo",
                "path": url.path,
                "resource_uri": url.absoluteString,
                "mime_type": "image/jpeg",
                "bytes": imageData.count,
                "width": config.photo.width,
                "height": config.photo.height,
                "quality": config.photo.quality,
                "created_at": ISO8601DateFormatter().string(from: Date())
            ]
            return ToolResult(content: [
                .text(compactJSON(metadata)),
                .image(IMAGEContent(data: imageData.base64EncodedString(), mimeType: "image/jpeg"))
            ])

        case .failure(let error):
            return ToolResult(
                content: [.text("{\"ok\": false, \"error\": \"\(error.localizedDescription)\"}")],
                isError: true
            )
        }
    }

    // MARK: - camera_capture_frames

    private static func cameraCaptureFrames(
        params: CallTool.Params,
        config: PeekConfig,
        paths: PeekPaths,
        cameraController: CameraSessionController
    ) async -> ToolResult {
        let count = min(params.arguments?["count"]?.intValue ?? config.frame.count, 30)
        let fps = min(max(params.arguments?["fps"]?.intValue ?? config.frame.fps, 1), 30)
        let qualityArg = params.arguments?["quality"]?.stringValue ?? "medium"
        let deviceID = params.arguments?["device_id"]?.stringValue ?? config.camera.defaultDeviceId
        let quality = CaptureQuality(rawValue: qualityArg) ?? .medium

        let result = await cameraController.captureFrames(
            count: count,
            fps: fps,
            quality: quality,
            frameConfig: config.frame,
            deviceID: deviceID,
            paths: paths
        )

        switch result {
        case .success(let (urls, manifest)):
            var images: [IMAGEContent] = []
            for url in urls {
                if let data = try? Data(contentsOf: url) {
                    images.append(IMAGEContent(data: data.base64EncodedString(), mimeType: "image/jpeg"))
                }
            }
            let metadata: [String: Any] = [
                "ok": true,
                "type": "frames",
                "count": images.count,
                "fps": fps,
                "frames_dir": manifest.framesDirectory.path,
                "created_at": manifest.createdAt
            ]
            var content: [ToolResultContent] = [.text(compactJSON(metadata))]
            content.append(contentsOf: images.map { .image($0) })
            return ToolResult(content: content)

        case .failure(let error):
            return ToolResult(
                content: [.text("{\"ok\": false, \"error\": \"\(error.localizedDescription)\"}")],
                isError: true
            )
        }
    }

    // MARK: - camera_record_video

    private static func cameraRecordVideo(
        params: CallTool.Params,
        config: PeekConfig,
        paths: PeekPaths,
        cameraController: CameraSessionController
    ) async -> ToolResult {
        let requestedDuration = params.arguments?["duration_seconds"]?.doubleValue ?? 5.0
        let duration = max(Double(config.video.minDurationSeconds),
                          min(requestedDuration, Double(config.video.maxDurationSeconds)))
        let deviceID = params.arguments?["device_id"]?.stringValue ?? config.camera.defaultDeviceId

        let result = await cameraController.recordVideo(
            durationSeconds: duration,
            videoConfig: config.video,
            deviceID: deviceID,
            paths: paths
        )

        switch result {
        case .success(let url):
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let metadata: [String: Any] = [
                "ok": true,
                "type": "video",
                "mime_type": "video/mp4",
                "path": url.path,
                "resource_uri": url.absoluteString,
                "duration_seconds": duration,
                "bytes": fileSize,
                "width": config.video.width,
                "height": config.video.height,
                "fps": config.video.fps,
                "created_at": ISO8601DateFormatter().string(from: Date())
            ]
            return ToolResult(content: [.text(compactJSON(metadata))])

        case .failure(let error):
            return ToolResult(
                content: [.text("{\"ok\": false, \"error\": \"\(error.localizedDescription)\"}")],
                isError: true
            )
        }
    }

    // MARK: - Helpers

    private static func compactJSON(_ dict: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"ok\": false, \"error\": \"metadata serialization failed\"}"
        }
    }
}
```

### 6.3 PeekResources

```swift
public struct PeekResources {
    public static func list(paths: PeekPaths) -> ResourceList {
        let capturesDir = paths.captures
        let fm = FileManager.default

        var resources: [Resource] = []

        // Root captures: snapshots and videos
        if let rootURLs = try? fm.contentsOfDirectory(
            at: capturesDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) {
            let recent = rootURLs
                .filter { ["jpg", "jpeg", "mp4"].contains($0.pathExtension.lowercased()) }
                .sorted {
                    ($0.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast) >
                    ($1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast)
                }
                .prefix(20)

            for url in recent {
                resources.append(Resource(
                    uri: url.absoluteString,
                    name: url.lastPathComponent,
                    description: "Peek capture: \(url.lastPathComponent)",
                    mimeType: mimeType(for: url)
                ))
            }
        }

        // Frame burst manifests
        if let dirURLs = try? fm.contentsOfDirectory(
            at: capturesDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for dirURL in dirURLs {
                let isDir = (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDir && dirURL.lastPathComponent.hasPrefix("frames_") {
                    let manifestURL = dirURL.appendingPathComponent("manifest.json")
                    if fm.fileExists(atPath: manifestURL.path) {
                        resources.append(Resource(
                            uri: manifestURL.absoluteString,
                            name: "\(dirURL.lastPathComponent)/manifest.json",
                            description: "Peek frame burst manifest",
                            mimeType: "application/json"
                        ))
                    }
                }
            }
        }

        return ResourceList(resources: resources)
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
}
```

---

## 7. Menu Bar UI

### 7.1 PeekController — UI ↔ Server Bridge

```swift
@MainActor
public final class PeekController: ObservableObject {
    public let appState: AppState
    private let configLoader: ConfigLoader
    private var config: PeekConfig
    private var serverManager: MCPServerManager?

    public init() {
        self.appState = AppState()
        self.configLoader = ConfigLoader()
        self.config = PeekConfig()
        self.serverManager = nil
    }

    public func loadConfig() -> ConfigLoadResult {
        let result = configLoader.load()
        switch result {
        case .loaded(let cfg), .createdDefault(let cfg):
            self.config = cfg
        case .invalid(let err, let fallback):
            self.config = fallback
            appState.markError("Config: \(err)")
        }
        // Create serverManager AFTER config is loaded, with real config
        self.serverManager = MCPServerManager(config: self.config)
        appState.autoStartEnabled = self.config.app.autoStart
        appState.permissionText = PermissionService.shared.cameraAuthorizationStatus()
        return result
    }

    public func startServer() {
        Task {
            appState.markStarting()
            do {
                guard let manager = serverManager else {
                    appState.markError("Server not initialized")
                    return
                }
                let port = try await manager.start()
                appState.markRunning(port: port)
            } catch {
                appState.markError(error.localizedDescription)
            }
        }
    }

    public func stopServer() {
        Task {
            appState.markStopping()
            await serverManager?.stop()
            appState.markIdle()
        }
    }

    public var currentConfig: PeekConfig {
        config
    }
}
```

### 7.2 AppState

```swift
@MainActor
@Observable
public final class AppState {
    public var statusText = "Starting"
    public var serverStatus: ServerStatus = .idle
    public var port: Int?
    public var permissionText = "Unknown"
    public var lastCapturePath: String?
    public var errorMessage: String?
    public var autoStartEnabled: Bool?

    public enum ServerStatus {
        case idle, starting, running, stopping, error
    }

    public func markIdle() {
        serverStatus = .idle
        port = nil
        errorMessage = nil
        statusText = "MCP Server Stopped"
    }

    public func markRunning(port: Int) {
        serverStatus = .running
        self.port = port
        errorMessage = nil
        statusText = "MCP Server Running"
    }

    public func markStarting() {
        serverStatus = .starting
        errorMessage = nil
        statusText = "Starting..."
    }

    public func markStopping() {
        serverStatus = .stopping
        statusText = "Stopping..."
    }

    public func markError(_ msg: String) {
        serverStatus = .error
        errorMessage = msg
        statusText = "Error"
    }
}
```

### 7.3 MenuBarView

```swift
import SwiftUI

public struct MenuBarView: View {
    @Bindable public var state: AppState
    private let onStart: () -> Void
    private let onStop: () -> Void

    public init(state: AppState, onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.state = state
        self.onStart = onStart
        self.onStop = onStop
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text("Peek")
                    .font(.headline)
            }

            Divider()

            switch state.serverStatus {
            case .idle:
                Label("MCP Server: Stopped", systemImage: "stop.circle")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

            case .starting, .stopping:
                Label(
                    "MCP Server: \(state.serverStatus == .starting ? "Starting" : "Stopping")...",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.subheadline)
                .foregroundColor(.orange)

            case .running:
                VStack(alignment: .leading, spacing: 4) {
                    Label("MCP Server: Running", systemImage: "play.circle")
                        .font(.subheadline)
                        .foregroundColor(.green)
                    Text("Camera: \(state.permissionText)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let port = state.port {
                        Text("Port: \(port)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("http://127.0.0.1:\(port)/mcp")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

            case .error:
                Label("MCP Server: Error", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundColor(.red)
                if let msg = state.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            Divider()

            HStack {
                Image(systemName: "camera")
                    .foregroundColor(.secondary)
                Text("Camera: \(state.permissionText)")
                    .font(.subheadline)
            }

            if let last = state.lastCapturePath {
                Divider()
                Text("Last: \(last)")
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Divider()

            if state.serverStatus == .running {
                Button("Stop Server", role: .destructive) { onStop() }
            } else if state.serverStatus == .idle {
                Button("Start Server") { onStart() }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(width: 300, alignment: .leading)
        .padding(12)
    }

    private var statusColor: Color {
        switch state.serverStatus {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .error: return .red
        case .idle: return .gray
        }
    }
}
```

### 7.4 PeekApp (Entry Point)

```swift
import SwiftUI

@main
struct PeekApp: App {
    @NSApplicationDelegateAdaptor(PeekAppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        MenuBarExtra("Peek", systemImage: statusIcon) {
            MenuBarView(
                state: appDelegate.controller.appState,
                onStart: { appDelegate.controller.startServer() },
                onStop: { appDelegate.controller.stopServer() }
            )
        }
    }

    private var statusIcon: String {
        switch appDelegate.controller.appState.serverStatus {
        case .running: return "camera.fill"
        default: return "camera"
        }
    }
}
```

### 7.5 PeekAppDelegate

```swift
import AppKit
import Foundation

@MainActor
public final class PeekAppDelegate: NSObject, NSApplicationDelegate {
    public let controller = PeekController()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let result = controller.loadConfig()

        if case .invalid(let err, _) = result {
            controller.appState.markError("Config: \(err)")
        }

        // Auto-start if configured (works for .loaded and .createdDefault)
        if controller.currentConfig.app.autoStart {
            controller.startServer()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        Task {
            await controller.stopServer()
        }
    }
}
```

---

## 8. Privacy & Security Model

### 8.1 Privacy Principles

| Principle | Implementation |
|-----------|---------------|
| **No silent capture** | Server must be manually started by user. Menu bar indicator shows when running. |
| **Local-only storage** | All captures in `~/Library/Application Support/Peek/Captures/`. No cloud upload. |
| **No microphone in V1** | Video records H.264 without AAC audio track. No `NSMicrophoneUsageDescription`. |
| **No remote binding** | Server binds to `127.0.0.1` only. Cannot be enabled in V1. |
| **Same-user gate** | macOS camera permission is the access control. Any process as current user with camera permission can call. |
| **Audit trail** | Every tool call logged to `captures.log` as JSONL with timestamp, tool, duration, outcome. |

### 8.2 V1 Security Acceptance Criteria

- Server binds to `127.0.0.1` strictly
- No network exposure beyond loopback
- macOS camera permission is the gate
- Manual start default (auto-start opt-in only)
- All captures stored locally
- No microphone in V1
- `server.json` contains `auth_enabled: false` and `token: null` to make V1 auth state explicit

### 8.3 Audit Log Format (JSONL)

Each line is one valid JSON object (no trailing comma, no pretty print):

```json
{"timestamp":"2026-05-27T12:30:45Z","tool":"camera_snapshot","ok":true,"duration_ms":430}
{"timestamp":"2026-05-27T12:31:02Z","tool":"camera_record_video","ok":true,"duration_ms":5200}
{"timestamp":"2026-05-27T12:31:15Z","tool":"camera_status","ok":false,"duration_ms":12,"error":"permission denied"}
```

---

## 9. Implementation Components

### 9.1 CameraSessionController

```swift
public actor CameraSessionController {
    private var busy = false

    public func snapshot(
        deviceID: String?,
        quality: CaptureQuality,
        photoConfig: PeekConfig.PhotoConfig,
        paths: PeekPaths
    ) async -> Result<URL, CaptureError> {
        guard !busy else { return .failure(.cameraBusy) }
        busy = true
        defer { busy = false }

        let profile = QualityProfile(preset: quality, baseWidth: photoConfig.width, baseHeight: photoConfig.height)
        let capturer = AVFoundationPhotoCapturer()

        do {
            let data = try await capturer.capturePhoto(
                deviceID: deviceID,
                width: profile.width,
                height: profile.height,
                jpegQuality: profile.jpegQuality
            )
            let store = SecureImageStore(paths: paths)
            let path = try store.writeJPEG(data, kind: .photo)
            return .success(path)
        } catch {
            return .failure(.captureFailed(error.localizedDescription))
        }
    }

    public func captureFrames(
        count: Int,
        fps: Int,
        quality: CaptureQuality,
        frameConfig: PeekConfig.FrameConfig,
        deviceID: String?,
        paths: PeekPaths
    ) async -> Result<([URL], FrameBurstManifest), CaptureError> {
        guard !busy else { return .failure(.cameraBusy) }
        busy = true
        defer { busy = false }

        // Capture using FrameBurstCapturer
        let capturer = FrameBurstCapturer(config: frameConfig)
        do {
            let (urls, manifest) = try await capturer.capture(
                count: count,
                fps: fps,
                quality: quality,
                deviceID: deviceID,
                paths: paths
            )
            return .success((urls, manifest))
        } catch {
            return .failure(.captureFailed(error.localizedDescription))
        }
    }

    public func recordVideo(
        durationSeconds: Double,
        videoConfig: PeekConfig.VideoConfig,
        deviceID: String?,
        paths: PeekPaths
    ) async -> Result<URL, CaptureError> {
        guard !busy else { return .failure(.cameraBusy) }
        busy = true
        defer { busy = false }

        let capturer = VideoCapturer(config: videoConfig)
        do {
            let url = try await capturer.capture(
                durationSeconds: durationSeconds,
                deviceID: deviceID,
                paths: paths
            )
            return .success(url)
        } catch {
            return .failure(.captureFailed(error.localizedDescription))
        }
    }
}
```

### 9.2 AuditLogger

```swift
public actor AuditLogger {
    private let paths: PeekPaths
    private var handle: FileHandle?

    public init(paths: PeekPaths = PeekPaths()) {
        self.paths = paths
    }

    public func start() throws {
        try paths.ensureDirectories()
        let url = paths.capturesLogPath

        if FileManager.default.fileExists(atPath: url.path) {
            self.handle = try FileHandle(forWritingTo: url)
            try self.handle?.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.handle = try FileHandle(forWritingTo: url)
        }
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    public func log(tool: String, ok: Bool, durationMs: Int, error: String? = nil) {
        var entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "tool": tool,
            "ok": ok,
            "duration_ms": durationMs
        ]
        if let error {
            entry["error"] = error
        }

        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }

        var line = data
        line.append(0x0A)  // newline

        if let handle = self.handle {
            try? handle.write(contentsOf: line)
        } else {
            // Fallback: open/append/close
            let url = paths.capturesLogPath
            if let h = try? FileHandle(forWritingTo: url) {
                try? h.seekToEnd()
                try? h.write(contentsOf: line)
                try? h.close()
            }
        }
    }
}
```

### 9.3 PermissionService

```swift
import AVFoundation
import Foundation

public final class PermissionService: Sendable {
    public static let shared = PermissionService()

    private init() {}

    public func cameraAuthorizationStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }
}
```

### 9.4 CaptureStore Protocol

```swift
public enum CaptureKind: Sendable {
    case photo
    case frame
    case video
}

public protocol CaptureStore: Sendable {
    func writeJPEG(_ data: Data, kind: CaptureKind) throws -> URL
    func writeFrameJPEG(_ data: Data, directory: URL, index: Int) throws -> URL
    func writeManifest(_ manifest: FrameBurstManifest, directory: URL) throws
}
```

### 9.5 SecureImageStore

Implements `CaptureStore`. Atomic write with `O_WRONLY | O_CREAT | O_EXCL` + `chmod 0600` on the file.

### 9.6 FrameBurstManifest

```swift
public struct FrameBurstManifest: Codable, Sendable {
    public let framesDirectory: URL
    public let count: Int
    public let fps: Int
    public let quality: CaptureQuality
    public let createdAt: String

    public init(framesDirectory: URL, count: Int, fps: Int, quality: CaptureQuality) {
        self.framesDirectory = framesDirectory
        self.count = count
        self.fps = fps
        self.quality = quality
        self.createdAt = ISO8601DateFormatter().string(from: Date())
    }
}
```

### 9.7 StoragePruner

```swift
public struct StoragePruner: Sendable {
    private let paths: PeekPaths
    private let config: PeekConfig.StorageConfig

    public init(paths: PeekPaths = PeekPaths(), config: PeekConfig.StorageConfig) {
        self.paths = paths
        self.config = config
    }

    public func prune() throws {
        guard config.pruneOnStart else { return }

        let fm = FileManager.default
        let capturesDir = paths.captures

        // 1. Delete files older than maxCaptureAgeDays
        let cutoff = Date().addingTimeInterval(-Double(config.maxCaptureAgeDays) * 86400)
        if let urls = try? fm.contentsOfDirectory(
            at: capturesDir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) {
            for url in urls {
                if isDirectory(url) {
                    // frame burst directory: check manifest date
                    let manifestURL = url.appendingPathComponent("manifest.json")
                    if let attrs = try? fm.attributesOfItem(atPath: manifestURL.path),
                       let created = attrs[.creationDate] as? Date, created < cutoff {
                        try? fm.removeItem(at: url)
                    }
                } else if let attrs = try? fm.attributesOfItem(atPath: url.path),
                          let created = attrs[.creationDate] as? Date, created < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }

        // 2. If total size > maxTotalSizeMB, delete oldest until under limit
        let maxBytes = config.maxTotalSizeMB * 1024 * 1024
        while computeTotalSize(at: capturesDir) > maxBytes {
            guard let oldestURL = oldestFile(at: capturesDir) else { break }
            try? fm.removeItem(at: oldestURL)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func computeTotalSize(at url: URL) -> Int {
        let fm = FileManager.default
        var total = 0
        if let urls = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: .skipsHiddenFiles
        ) {
            for u in urls {
                if isDirectory(u) {
                    total += computeTotalSize(at: u)
                } else if let size = try? fm.attributesOfItem(atPath: u.path)[.size] as? Int {
                    total += size
                }
            }
        }
        return total
    }

    private func oldestFile(at url: URL) -> URL? {
        let fm = FileManager.default
        var oldest: URL?
        var oldestDate: Date = .distantFuture

        if let urls = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ) {
            for u in urls {
                if let date = try? u.resourceValues(forKeys: [.creationDateKey]).creationDate, date < oldestDate {
                    oldestDate = date
                    oldest = u
                }
            }
        }
        return oldest
    }
}
```

### 9.8 ServerInfoStore

Responsibilities: write, read, delete, and stale-cleanup of `server.json`.

```swift
public enum ServerInfoStore: Sendable {
    private static let paths = PeekPaths()

    public struct Info: Codable {
        public let pid: Int32
        public let port: Int
        public let host: String
        public let endpoint: String
        public let token: String?
        public let authEnabled: Bool
        public let startedAt: String

        enum CodingKeys: String, CodingKey {
            case pid, port, host, endpoint, token
            case authEnabled = "auth_enabled"
            case startedAt = "started_at"
        }
    }

    /// Write server.json with current runtime info
    public static func write(port: Int, host: String) throws {
        let info: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "port": port,
            "host": host,
            "endpoint": "http://\(host):\(port)/mcp",
            "token": NSNull(),
            "auth_enabled": false,
            "started_at": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
        try data.write(to: paths.serverInfoPath, options: .atomic)
    }

    /// Delete server.json (on graceful shutdown)
    public static func delete() throws {
        try FileManager.default.removeItem(at: paths.serverInfoPath)
    }

    /// Read server.json if it exists
    public static func read() -> Info? {
        guard let data = try? Data(contentsOf: paths.serverInfoPath) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    /// On app launch: delete server.json if the recorded pid is no longer running
    public static func cleanStale() {
        guard let info = read() else { return }
        let pid = info.pid
        let process = ProcessInfo.processInfo
        // Check if process with that pid exists ( Darwin pid 0/1 are always valid; skip)
        if pid <= 1 { return }
        let running = (try? Process(pid: pid, processName: nil).isRunning) ?? false
        if !running {
            try? delete()
        }
    }
}
```

---

## 10. Implementation Phases

### Phase 0 — Spike MCP Transport (MANDATORY BEFORE EVERYTHING)

**Goal:** Validate that `StatefulHTTPServerTransport` API from `modelcontextprotocol/swift-sdk@0.11.0` matches this contract.

```
1. Create minimal SwiftPM project with MCP dependency
2. Implement single tool: peek_ping → {"ok": true}
3. Start server on 127.0.0.1:8765/mcp
4. Verify with: npx -y @modelcontextprotocol/inspector
5. Confirm:
   - exact endpoint path (/mcp vs /sse)
   - init signature for StatefulHTTPServerTransport
   - server.stop() / transport.close() graceful shutdown
   - ToolList and ToolResult types
   - ListTools handler registration
6. If API differs from this spec, update contract BEFORE proceeding
```

**Deliverable:** Confirmed SDK API surface. Spike results inform actual implementation.

### Phase 1 — App Shell

```
1. PeekPaths, ConfigLoader, PeekConfig
2. PeekApp + PeekAppDelegate + PeekController
3. MenuBarView with status indicator
4. MCPServerManager (start/stop, port allocation)
5. AuditLogger (actor + FileHandle, start/close)
6. swift build -c release
7. make app (bundle with Info.plist)
8. Verify: menu bar icon, Start/Stop, server.json
```

### Phase 2 — Tool Registry + Status/List

```
1. PeekToolRegistry.listTools() with all 5 tools
2. PeekToolHandlers with status and list handlers
3. Wire MCPServerManager with ListTools + CallTool + ListResources
4. Test with MCP Inspector
5. Verify tools/list returns camera_status, camera_list, camera_snapshot, camera_capture_frames, camera_record_video
```

### Phase 3 — Snapshot

```
1. Wire CameraSessionController to snapshot handler
2. AVFoundationPhotoCapturer + SecureImageStore
3. PermissionService for NSCameraUsageDescription
4. camera_snapshot returns ImageContent + text metadata
5. AuditLogger.log() called for every tool call
6. Prune on startup (StoragePruner)
```

### Phase 4 — Frame Burst

```
1. FrameBurstCapturer implementation
2. Clamp count (1-30), fps (1-30)
3. CaptureMetadata + FrameBurstManifest
4. camera_capture_frames returns ImageContent[] + metadata
5. Manifest registered as resource
```

### Phase 5 — Video Recording

```
1. VideoCapturer (H.264 MP4 without AAC)
2. camera_record_video returns resource_uri text metadata (NO ImageContent)
3. Video file created in Captures/
```

### Phase 6 — Hardening

```
1. server.json includes pid + auth_enabled=false + token=null
2. stale server.json detection on startup
3. graceful shutdown (server.stop() + transport.close())
4. LSUIElement + NSCameraUsageDescription in Info.plist
5. codesign --force --deep --sign - Peek.app
6. Final MCP Inspector test: all 5 tools confirmed working
```

---

## 11. Refactoring Plan

### 11.1 Delete

```
plugin/                                              → DELETE (no Python plugin)
macos/Sources/HermesCameraApp/IPC/                   → DELETE (IPCModels, JSONLineCodec)
macos/Sources/HermesCameraApp/Services/SocketServer.swift   → DELETE
macos/Sources/HermesCameraApp/App/CameraRuntime.swift        → DELETE
/Agents.md                                           → DELETE (old spec)
HERMES-CAMERA-MCP.md                                 → DELETE (superseded)
```

### 11.2 Rename

```
HermesPaths.swift                  → PeekPaths.swift
HermesCameraAppDelegate            → PeekAppDelegate
HermesCameraApp                    → PeekApp
```

### 11.3 Source Tree After Refactor

```
hermes-camera/macos/Sources/Peek/
├── App/
│   ├── PeekApp.swift
│   ├── PeekAppDelegate.swift
│   └── PeekController.swift
├── MCP/
│   ├── MCPServerManager.swift
│   ├── PeekToolRegistry.swift
│   ├── PeekToolHandlers.swift
│   └── PeekResources.swift
├── Camera/
│   ├── CameraSessionController.swift
│   ├── PermissionService.swift
│   ├── CameraDeviceProvider.swift
│   ├── AVFoundationPhotoCapturer.swift
│   ├── FrameBurstCapturer.swift
│   └── VideoCapturer.swift
├── Storage/
│   ├── PeekPaths.swift
│   ├── CaptureStore.swift
│   ├── SecureImageStore.swift
│   ├── StoragePruner.swift
│   ├── AuditLogger.swift
│   └── ServerInfoStore.swift
├── Config/
│   ├── PeekConfig.swift
│   └── ConfigLoader.swift
├── Models/
│   ├── CameraDevice.swift
│   ├── CaptureQuality.swift
│   ├── CaptureErrors.swift
│   └── CaptureMetadata.swift
└── Views/
    └── MenuBarView.swift
```

### 11.4 Package.swift

```swift
import PackageDescription

let package = Package(
    name: "Peek",
    platforms: [.macOS("14.0")],
    products: [
        .executable(
            name: "Peek",
            targets: ["Peek"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "Peek",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/Peek"
        ),
        .testTarget(
            name: "PeekTests",
            dependencies: ["Peek"],
            path: "Tests/PeekTests"
        )
    ]
)
```

**Note:** No swift-testing dependency. Use XCTest for V1.

---

## 12. Build & Run

### 12.1 Build

```bash
cd hermes-camera/macos
swift build -c release
```

### 12.2 App Bundle (Makefile)

```makefile
.PHONY: app install clean

app: build
	mkdir -p Peek.app/Contents/MacOS
	mkdir -p Peek.app/Contents/Resources
	cp .build/apple/Products/release/Peek Peek.app/Contents/MacOS/
	cp Info.plist Peek.app/Contents/
	cp Peek.entitlements Peek.app/Contents/
	chmod +x Peek.app/Contents/MacOS/Peek

install: app
	cp -R Peek.app /Applications/Peek.app

clean:
	rm -rf Peek.app
```

### 12.3 Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.peek.app</string>
    <key>CFBundleName</key><string>Peek</string>
    <key>CFBundleVersion</key><string>1.0.0</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Peek</string>
    <key>CFBundleDisplayName</key><string>Peek</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSCameraUsageDescription</key><string>Peek needs camera access to capture photos and videos when requested by an MCP client.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
```

### 12.4 Entitlements

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
```

**Sandbox:** OFF. Camera access and file writes in user-scoped directories are not compatible with App Sandbox in V1.

### 12.5 Signing

```bash
codesign --force --deep --sign - Peek.app
```

Ad-hoc signing sufficient for local development/distribution outside Mac App Store.

### 12.6 MCP Client Configurations

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "peek": {
      "url": "http://127.0.0.1:8765/mcp"
    }
  }
}
```

**MCP Inspector:**

```bash
npx -y @modelcontextprotocol/inspector
# Connect to: http://127.0.0.1:8765/mcp
```

---

## 13. Testing Matrix

### 13.1 Unit Tests

| Test | Target |
|------|--------|
| ConfigLoader decodes snake_case JSON with `auto_start` | ConfigLoader |
| ConfigLoader round-trips encode/decode with snake_case | ConfigLoader |
| ConfigLoader creates default on missing file | ConfigLoader |
| ConfigLoader returns .invalid on broken JSON | ConfigLoader |
| PeekPaths.ensureDirectories() creates dirs with mode 0700 | PeekPaths |
| PeekPaths.logs resolves to `~/Library/Logs/Peek/` | PeekPaths |
| PeekToolRegistry.listTools() returns 5 tools | PeekToolRegistry |
| AuditLogger.start() opens FileHandle | AuditLogger |
| AuditLogger.log() writes JSONL line | AuditLogger |
| AuditLogger.close() closes FileHandle | AuditLogger |
| StoragePruner.prune() respects max_capture_age_days | StoragePruner |
| StoragePruner.prune() respects max_total_size_mb | StoragePruner |
| CameraSessionController rejects concurrent calls (busy policy) | CameraSessionController |
| QualityProfile resolves width/height/jpegQuality per preset | QualityProfile |

### 13.2 Integration Tests

| Test | Method |
|------|--------|
| Server starts, server.json has pid + token=null + auth_enabled=false | Start + read JSON |
| server.json deleted after stop | Start then stop |
| tools/list returns 5 tools | ListTools call |
| camera_status returns JSON with camera_permission | Call + parse JSON |
| camera_list returns JSON with devices array | Call + parse JSON |
| camera_snapshot returns ImageContent + text metadata | Call + inspect content |
| camera_capture_frames returns ImageContent[] ≤ 30 | Call + count images |
| camera_record_video returns text with path/resource_uri (no image) | Call + inspect content |
| Concurrent calls rejected when camera busy | Call during active capture |
| Stale server.json cleaned on next launch | Kill process, launch again |

### 13.3 Manual Tests

| Scenario | Expected |
|----------|----------|
| App launch without config | Creates config.json with defaults |
| Start Server → menu bar ● appears | Running state confirmed |
| Connect MCP Inspector to http://127.0.0.1:8765/mcp | Tools discoverable |
| camera_permission = not_determined on fresh install | Status reflects reality |
| Camera used by FaceTime → camera_snapshot | Returns camera_busy error |
| Record 60s video → file is H.264 without audio track | ffprobe confirms no audio |
| Quit app while running → server.json deleted | Clean shutdown confirmed |
| Permissions revoked → camera_status reflects denied | Correct error state |

---

## Appendix A: Config Schema

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `app.name` | string | "Peek" | App display name |
| `app.auto_start` | bool | false | Start server on app launch |
| `server.host` | string | "127.0.0.1" | Bind host (V1 always 127.0.0.1) |
| `server.port` | int | 8765 | MCP server port |
| `camera.default_device_id` | string\|null | null | Default device ID |
| `camera.default_quality` | string | "medium" | Default quality preset |
| `photo.width` | int | 1920 | Photo width in px |
| `photo.height` | int | 1080 | Photo height in px |
| `photo.quality` | int | 85 | JPEG quality (0-100) |
| `frame.width` | int | 1920 | Frame capture width |
| `frame.height` | int | 1080 | Frame capture height |
| `frame.quality` | int | 75 | Frame JPEG quality |
| `frame.count` | int | 10 | Default frame count (max 30) |
| `frame.fps` | int | 30 | Frames per second (1-30) |
| `video.width` | int | 1280 | Video width |
| `video.height` | int | 720 | Video height |
| `video.quality` | int | 75 | Video quality |
| `video.min_duration_seconds` | int | 3 | Minimum recording |
| `video.max_duration_seconds` | int | 60 | Maximum recording |
| `video.fps` | int | 30 | Video framerate |
| `storage.max_total_size_mb` | int | 2048 | Max storage before prune |
| `storage.max_capture_age_days` | int | 7 | Max age before prune |
| `storage.prune_on_start` | bool | true | Prune on app start |
| `security.require_local_token` | bool | false | Reserved for V1.5 |

---

## Appendix B: Info.plist & Entitlements

### Required Info.plist Keys

```xml
<key>LSUIElement</key>
<true/>
<key>NSCameraUsageDescription</key>
<string>Peek needs camera access to capture photos and videos when requested by an MCP client.</string>
```

- `LSUIElement = true` hides Dock icon. App runs as menu bar only.
- `NSCameraUsageDescription` is required for camera access on macOS.

### Entitlements

```xml
<key>com.apple.security.device.camera</key>
<true/>
```

Sandbox is OFF. Camera access and arbitrary file writes to `~/Library/Application Support/Peek/` are not compatible with App Sandbox restrictions in V1.

---

## Appendix C: Naming & Structure Rules

### Naming Rule

**No file, class, struct, enum, or type may contain "Hermes" or "HermesCamera" anywhere.** Peek must be independently identifiable and free of framework coupling.

### Directory Structure Rule

```
Sources/Peek/
├── App/          — PeekApp, PeekAppDelegate, PeekController
├── MCP/          — MCPServerManager, PeekToolRegistry, PeekToolHandlers, PeekResources
├── Camera/       — CameraSessionController, PermissionService,
                                  AVFoundationPhotoCapturer, FrameBurstCapturer, VideoCapturer
├── Storage/      — PeekPaths, CaptureStore, SecureImageStore, StoragePruner, AuditLogger
├── Config/       — PeekConfig, ConfigLoader
├── Models/       — CameraDevice, CaptureQuality, CaptureErrors, CaptureMetadata
└── Views/        — MenuBarView
```

### Ownership Rule

**CameraSessionController is the sole owner of camera operations.** No tool handler may directly instantiate `CameraCaptureService`, `AVFoundationPhotoCapturer`, `FrameBurstCapturer`, or `VideoCapturer`. All routing goes through `CameraSessionController`.

### AuditLogger Rule

**AuditLogger is a singleton actor owned by MCPServerManager.** Created once, used by all tool handlers for logging. Writes JSONL to `~/Library/Logs/Peek/captures.log`.

### Config Rule

**Config is loaded once in PeekController.loadConfig() before MCPServerManager is created.** The server manager receives the actual config, never defaults.