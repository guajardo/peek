import Foundation
import Network

final class MCPServer {
    enum ServerState {
        case stopped
        case running(port: UInt16)
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.peek.mcp.server")
    private(set) var state: ServerState = .stopped

    private let camera = Camera.shared

    // MARK: - Server Lifecycle

    func start(port: UInt16 = 8765) throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let nwListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        nwListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.state = .running(port: port)
            case .failed, .cancelled:
                self?.state = .stopped
                self?.listener = nil
            default:
                break
            }
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener = nwListener
        nwListener.start(queue: queue)
        state = .running(port: port)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    // MARK: - Connection Handling

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receive(on: connection)
            default:
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.process(data: data, connection: connection)
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self?.receive(on: connection)
            }
        }
    }

    private func process(data: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            self.sendError(connection: connection, code: -32700, message: "Parse error")
            return
        }

        let id = json["id"]
        let params = json["params"] as? [String: Any]

        let response: [String: Any]

        switch method {
        case "initialize":
            response = handleInitialize(id: id)
        case "tools/list":
            response = handleToolsList(id: id)
        case "tools/call":
            response = handleToolCall(id: id, params: params)
        default:
            sendError(connection: connection, code: -32601, message: "Method not found", id: id)
            return
        }

        send(response: response, connection: connection)
    }

    // MARK: - MCP Protocol

    private func handleInitialize(id: Any?) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "serverInfo": [
                    "name": "Peek",
                    "version": "1.0.0"
                ]
            ]
        ]
    }

    private func handleToolsList(id: Any?) -> [String: Any] {
        let tools: [[String: Any]] = [
            [
                "name": "peek_ping",
                "description": "Debug ping",
                "inputSchema": ["type": "object"]
            ],
            [
                "name": "camera_status",
                "description": "Camera service state",
                "inputSchema": ["type": "object"]
            ],
            [
                "name": "camera_snapshot",
                "description": "Take a photo",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "quality": ["type": "string", "enum": ["low", "medium", "high"], "default": "medium"]
                    ]
                ]
            ],
            [
                "name": "camera_start_recording",
                "description": "Start video recording",
                "inputSchema": ["type": "object"]
            ],
            [
                "name": "camera_stop_recording",
                "description": "Stop video recording",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": ["type": "string"]
                    ]
                ]
            ],
            [
                "name": "camera_frames",
                "description": "Capture frame burst",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "count": ["type": "number", "minimum": 1, "maximum": 30, "default": 10],
                        "quality": ["type": "string", "enum": ["low", "medium", "high"], "default": "medium"]
                    ]
                ]
            ]
        ]

        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": ["tools": tools]
        ]
    }

    private func handleToolCall(id: Any?, params: [String: Any]?) -> [String: Any] {
        guard let params = params,
              let toolName = params["name"] as? String else {
            return errorResponse(id: id, code: -32602, message: "Invalid params")
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch toolName {
        case "peek_ping":
            return handlePing(id: id, arguments: arguments)
        case "camera_status":
            return handleCameraStatus(id: id, arguments: arguments)
        case "camera_snapshot":
            return handleSnapshot(id: id, arguments: arguments)
        case "camera_start_recording":
            return handleStartRecording(id: id, arguments: arguments)
        case "camera_stop_recording":
            return handleStopRecording(id: id, arguments: arguments)
        case "camera_frames":
            return handleFrames(id: id, arguments: arguments)
        default:
            return errorResponse(id: id, code: -32601, message: "Tool not found: \(toolName)")
        }
    }

    // MARK: - Tool Handlers

    private func handlePing(id: Any?, arguments: [String: Any]) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "ok": true,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
        ]
    }

    private func handleCameraStatus(id: Any?, arguments: [String: Any]) -> [String: Any] {
        let permStatus = camera.checkPermission()
        let serverRunning: Bool
        if case .running = state {
            serverRunning = true
        } else {
            serverRunning = false
        }

        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "ok": true,
                "server_running": serverRunning,
                "camera_permission": String(describing: permStatus).lowercased()
            ]
        ]
    }

    private func handleSnapshot(id: Any?, arguments: [String: Any]) -> [String: Any] {
        let qualityStr = arguments["quality"] as? String ?? "medium"
        let quality = Camera.Quality(rawValue: qualityStr) ?? .medium

        var response: [String: Any]!
        let sem = DispatchSemaphore(value: 0)

        camera.takeSnapshot(quality: quality) { result in
            switch result {
            case .success(let url):
                response = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "ok": true,
                        "image_path": url.path,
                        "width": 1920,
                        "height": 1080
                    ]
                ]
            case .failure(let error):
                response = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "ok": false,
                        "error": error.localizedDescription
                    ]
                ]
            }
            sem.signal()
        }

        sem.wait()
        return response
    }

    private func handleStartRecording(id: Any?, arguments: [String: Any]) -> [String: Any] {
        var response: [String: Any]!
        let sem = DispatchSemaphore(value: 0)

        camera.startRecording { result in
            switch result {
            case .success(let (recordingID, startedAt)):
                response = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "ok": true,
                        "recording_id": recordingID.uuidString,
                        "started_at": ISO8601DateFormatter().string(from: startedAt)
                    ]
                ]
            case .failure(let error):
                response = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "ok": false,
                        "error": error.localizedDescription
                    ]
                ]
            }
            sem.signal()
        }

        sem.wait()
        return response
    }

    private func handleStopRecording(id: Any?, arguments: [String: Any]) -> [String: Any] {
        guard let recordingIDStr = arguments["recording_id"] as? String,
              let recordingID = UUID(uuidString: recordingIDStr) else {
            return errorResponse(id: id, code: -32602, message: "Invalid recording_id")
        }

        var response: [String: Any]!
        let sem = DispatchSemaphore(value: 0)

        camera.stopRecording(recordingID: recordingID) { result in
            switch result {
            case .success(let (url, duration)):
                response = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "ok": true,
                        "video_path": url.path,
                        "duration_seconds": duration
                    ]
                ]
            case .failure(let error):
                response = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "ok": false,
                        "error": error.localizedDescription
                    ]
                ]
            }
            sem.signal()
        }

        sem.wait()
        return response
    }

    private func handleFrames(id: Any?, arguments: [String: Any]) -> [String: Any] {
        let count = arguments["count"] as? Int ?? 10
        let qualityStr = arguments["quality"] as? String ?? "medium"
        let quality = Camera.Quality(rawValue: qualityStr) ?? .medium

        var response: [String: Any]!
        let sem = DispatchSemaphore(value: 0)

        camera.captureFrames(count: count, quality: quality) { result in
            switch result {
            case .success(let framesData):
                let base64Frames = framesData.map { $0.base64EncodedString() }
                response = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "ok": true,
                        "frames": base64Frames,
                        "count": base64Frames.count
                    ]
                ]
            case .failure(let error):
                response = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "ok": false,
                        "error": error.localizedDescription
                    ]
                ]
            }
            sem.signal()
        }

        sem.wait()
        return response
    }

    // MARK: - Response Helpers

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "error": [
                "code": code,
                "message": message
            ]
        ]
    }

    private func sendError(connection: NWConnection, code: Int, message: String, id: Any? = nil) {
        let resp: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id as Any,
            "error": ["code": code, "message": message]
        ]
        send(response: resp, connection: connection)
    }

    private func send(response: [String: Any], connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil {
                connection.cancel()
            }
        })
    }
}
