import Foundation
import ImageIO
import Network

final class MCPServer {
    enum ServerState {
        case stopped
        case running(port: UInt16)
    }

    private final class ConnectionContext {
        var buffer = Data()
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.peek.mcp.server")
    private(set) var state: ServerState = .stopped

    private let camera = Camera.shared
    private let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    // MARK: - Server Lifecycle

    func start(port: UInt16 = 8765) throws {
        print("[MCPServer] start() called with port \(port)")
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let nwListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        nwListener.stateUpdateHandler = { [weak self] state in
            print("[MCPServer] listener state changed to: \(state)")
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
            print("[MCPServer] new connection received")
            self?.handle(connection: connection)
        }

        listener = nwListener
        print("[MCPServer] starting listener on port \(port)")
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
        print("[MCPServer] handle() called, connection state: \(connection.state)")
        let context = ConnectionContext()
        connection.stateUpdateHandler = { state in
            print("[MCPServer] connection state changed to: \(state)")
            switch state {
            case .ready:
                self.receive(on: connection, context: context)
            case .failed(let err):
                print("[MCPServer] connection failed: \(err)")
                connection.cancel()
            case .cancelled:
                print("[MCPServer] connection cancelled")
            default:
                print("[MCPServer] connection in unexpected state, not cancelling yet")
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, context: ConnectionContext) {
        print("[MCPServer] receive() called")
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            print("[MCPServer] receive callback - data: \(data?.count ?? 0) bytes, error: \(String(describing: error))")
            if let data = data, !data.isEmpty {
                context.buffer.append(data)
                while let requestData = self?.nextHTTPRequest(from: context) {
                    self?.process(data: requestData, connection: connection)
                }
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self?.receive(on: connection, context: context)
            }
        }
    }

    private func nextHTTPRequest(from context: ConnectionContext) -> Data? {
        let headerSeparator = Data([13, 10, 13, 10])
        guard let separatorRange = context.buffer.range(of: headerSeparator) else {
            return nil
        }

        let headerEnd = separatorRange.upperBound
        let headerData = context.buffer.prefix(separatorRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            context.buffer.removeAll()
            return nil
        }

        var contentLength = 0
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
                break
            }
        }

        let requestLength = headerEnd + contentLength
        guard context.buffer.count >= requestLength else {
            return nil
        }

        let requestData = Data(context.buffer.prefix(requestLength))
        context.buffer.removeSubrange(0..<requestLength)
        return requestData
    }

    private func process(data: Data, connection: NWConnection) {
        guard let requestText = String(data: data, encoding: .utf8) else {
            self.sendHTTPError(connection: connection, code: 400, message: "Bad Request")
            return
        }

        let lines = requestText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            self.sendHTTPError(connection: connection, code: 400, message: "Bad Request")
            return
        }

        let requestLine = lines[0]
        let parts = requestLine.split(separator: " ", maxSplits: 1)
        guard parts.count >= 2 else {
            self.sendHTTPError(connection: connection, code: 400, message: "Bad Request")
            return
        }

        let method = String(parts[0])
        let pathAndVersion = String(parts[1])
        let path = pathAndVersion.split(separator: " ").first.map(String.init) ?? pathAndVersion

        guard path == "/mcp" else {
            self.sendHTTPError(connection: connection, code: 404, message: "Not Found")
            return
        }

        guard method == "POST" else {
            self.sendHTTPError(connection: connection, code: 405, message: "Method Not Allowed")
            return
        }

        let bodyStartIndex = requestText.range(of: "\r\n\r\n")?.upperBound
        let bodyString: String
        if let start = bodyStartIndex {
            bodyString = String(requestText[start...])
        } else {
            bodyString = ""
        }

        guard let bodyData = bodyString.data(using: .utf8) else {
            self.sendHTTPError(connection: connection, code: 400, message: "Bad Request")
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            self.sendHTTPError(connection: connection, code: 400, message: "Bad Request")
            return
        }

        let id = json["id"]
        let hasID = json.keys.contains("id")
        let methodName = json["method"] as? String
        let params = json["params"] as? [String: Any]

        if !hasID, methodName?.hasPrefix("notifications/") == true {
            sendHTTPAccepted(connection: connection)
            return
        }

        guard let methodName else {
            self.sendHTTPError(connection: connection, code: 400, message: "Bad Request")
            return
        }

        switch methodName {
        case "initialize":
            sendHTTP(response: handleInitialize(id: id, params: params), connection: connection)
        case "tools/list":
            sendHTTP(response: handleToolsList(id: id), connection: connection)
        case "tools/call":
            sendHTTP(response: handleToolCall(id: id, params: params), connection: connection)
        default:
            sendHTTPError(connection: connection, code: 404, message: "Method not found", id: id)
        }
    }

    // MARK: - MCP Protocol

    private func handleInitialize(id: Any?, params: [String: Any]?) -> [String: Any] {
        let requestedVersion = params?["protocolVersion"] as? String
        let protocolVersion = supportedProtocolVersions.contains(requestedVersion ?? "")
            ? requestedVersion!
            : supportedProtocolVersions[0]

        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "protocolVersion": protocolVersion,
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
        let payload: [String: Any] = [
            "ok": true,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        return toolResultResponse(id: id, payload: payload)
    }

    private func handleCameraStatus(id: Any?, arguments: [String: Any]) -> [String: Any] {
        let permStatus = camera.checkPermission()
        let serverRunning: Bool
        if case .running = state {
            serverRunning = true
        } else {
            serverRunning = false
        }

        let payload: [String: Any] = [
            "ok": true,
            "server_running": serverRunning,
            "camera_permission": String(describing: permStatus).lowercased(),
            "camera_active": camera.isActive()
        ]
        return toolResultResponse(id: id, payload: payload)
    }

    private func handleSnapshot(id: Any?, arguments: [String: Any]) -> [String: Any] {
        let qualityStr = arguments["quality"] as? String ?? "medium"
        let quality = Camera.Quality(rawValue: qualityStr) ?? .medium

        var response: [String: Any]!
        let sem = DispatchSemaphore(value: 0)

        camera.takeSnapshot(quality: quality) { result in
            switch result {
            case .success(let url):
                let dimensions = self.imageDimensions(at: url) ?? (width: 1920, height: 1080)
                let payload: [String: Any] = [
                    "ok": true,
                    "image_path": url.path,
                    "width": dimensions.width,
                    "height": dimensions.height
                ]
                response = self.toolResultResponse(id: id, payload: payload)
            case .failure(let error):
                response = self.toolErrorResponse(id: id, message: String(describing: error))
            }
            sem.signal()
        }

        let timeoutResult = sem.wait(timeout: .now() + 10)
        if timeoutResult == .timedOut {
            return toolErrorResponse(id: id, message: "Operation timed out")
        }
        return response
    }

    private func handleStartRecording(id: Any?, arguments: [String: Any]) -> [String: Any] {
        var response: [String: Any]!
        let sem = DispatchSemaphore(value: 0)

        camera.startRecording { result in
            switch result {
            case .success(let (recordingID, startedAt)):
                let payload: [String: Any] = [
                    "ok": true,
                    "recording_id": recordingID.uuidString,
                    "started_at": ISO8601DateFormatter().string(from: startedAt)
                ]
                response = self.toolResultResponse(id: id, payload: payload)
            case .failure(let error):
                response = self.toolErrorResponse(id: id, message: String(describing: error))
            }
            sem.signal()
        }

        let timeoutResult = sem.wait(timeout: .now() + 10)
        if timeoutResult == .timedOut {
            return toolErrorResponse(id: id, message: "Operation timed out")
        }
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
                let payload: [String: Any] = [
                    "ok": true,
                    "video_path": url.path,
                    "duration_seconds": duration
                ]
                response = self.toolResultResponse(id: id, payload: payload)
            case .failure(let error):
                response = self.toolErrorResponse(id: id, message: String(describing: error))
            }
            sem.signal()
        }

        let timeoutResult = sem.wait(timeout: .now() + 10)
        if timeoutResult == .timedOut {
            return toolErrorResponse(id: id, message: "Operation timed out")
        }
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
                let payload: [String: Any] = [
                    "ok": true,
                    "frames": base64Frames,
                    "count": base64Frames.count
                ]
                response = self.toolResultResponse(id: id, payload: payload)
            case .failure(let error):
                response = self.toolErrorResponse(id: id, message: String(describing: error))
            }
            sem.signal()
        }

        let timeoutResult = sem.wait(timeout: .now() + 10)
        if timeoutResult == .timedOut {
            return toolErrorResponse(id: id, message: "Operation timed out")
        }
        return response
    }

    // MARK: - Response Helpers

    private func toolResultResponse(id: Any?, payload: [String: Any], isError: Bool = false) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": jsonString(payload)
                    ]
                ],
                "structuredContent": payload,
                "isError": isError
            ]
        ]
    }

    private func toolErrorResponse(id: Any?, message: String) -> [String: Any] {
        return toolResultResponse(
            id: id,
            payload: [
                "ok": false,
                "error": message
            ],
            isError: true
        )
    }

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }

    private func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

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

    private func sendHTTPError(connection: NWConnection, code: Int, message: String, id: Any? = nil) {
        let httpCode: String
        switch code {
        case 400: httpCode = "400 Bad Request"
        case 404: httpCode = "404 Not Found"
        case 405: httpCode = "405 Method Not Allowed"
        case 500: httpCode = "500 Internal Server Error"
        default: httpCode = "\(code)"
        }

        let body: String
        if let id = id {
            let jsonResp = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
            body = String(data: jsonResp ?? Data(), encoding: .utf8) ?? ""
        } else {
            body = ""
        }

        let response = "HTTP/1.1 \(httpCode)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.cancel()
        }
    }

    private func sendHTTPAccepted(connection: NWConnection) {
        let response = "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n"
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.cancel()
        }
    }

    private func sendHTTP(response: [String: Any], connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: response) else {
            connection.cancel()
            return
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""
        let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bodyString.utf8.count)\r\n\r\n\(bodyString)"
        if let httpData = httpResponse.data(using: .utf8) {
            connection.send(content: httpData, completion: .contentProcessed { error in
                if error != nil {
                    connection.cancel()
                }
            })
        } else {
            connection.cancel()
        }
    }

    private func send(response: [String: Any], connection: NWConnection) {
        sendHTTP(response: response, connection: connection)
    }
}
