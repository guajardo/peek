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

    private enum HTTPRequestReadResult {
        case request(Data)
        case needMoreData
        case badRequest
        case payloadTooLarge
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.peek.mcp.server")
    private let cameraWorkQueue = DispatchQueue(label: "com.peek.mcp.camera-work", qos: .userInitiated)
    private(set) var state: ServerState = .stopped

    private let camera = Camera.shared
    private let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private let maxHeaderBytes = 16 * 1024
    private let maxBodyBytes = 1024 * 1024
    private let maxBufferedBytes = 1024 * 1024 + 16 * 1024

    // MARK: - Server Lifecycle

    func start(port: UInt16 = 8765) throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listenPort = NWEndpoint.Port(rawValue: port)!
        let loopback = IPv4Address("127.0.0.1")!
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: listenPort)

        let nwListener = try NWListener(using: params)
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
        let context = ConnectionContext()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receive(on: connection, context: context)
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, context: ConnectionContext) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                context.buffer.append(data)
                guard context.buffer.count <= self.maxBufferedBytes else {
                    context.buffer.removeAll()
                    self.sendHTTPError(connection: connection, code: 413, message: "Payload Too Large")
                    return
                }

                parseLoop: while true {
                    switch self.nextHTTPRequest(from: context) {
                    case .request(let requestData):
                        self.process(data: requestData, connection: connection)
                    case .needMoreData:
                        break parseLoop
                    case .badRequest:
                        self.sendHTTPError(connection: connection, code: 400, message: "Bad Request")
                        return
                    case .payloadTooLarge:
                        self.sendHTTPError(connection: connection, code: 413, message: "Payload Too Large")
                        return
                    }
                }
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, context: context)
            }
        }
    }

    private func nextHTTPRequest(from context: ConnectionContext) -> HTTPRequestReadResult {
        let headerSeparator = Data([13, 10, 13, 10])
        guard let separatorRange = context.buffer.range(of: headerSeparator) else {
            if context.buffer.count > maxHeaderBytes {
                context.buffer.removeAll()
                return .payloadTooLarge
            }
            return .needMoreData
        }

        guard separatorRange.lowerBound <= maxHeaderBytes else {
            context.buffer.removeAll()
            return .payloadTooLarge
        }

        let headerEnd = separatorRange.upperBound
        let headerData = context.buffer.prefix(separatorRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            context.buffer.removeAll()
            return .badRequest
        }

        var contentLength = 0
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                guard let parsedContentLength = Int(value) else {
                    context.buffer.removeAll()
                    return .badRequest
                }
                contentLength = parsedContentLength
                break
            }
        }

        guard contentLength >= 0 && contentLength <= maxBodyBytes else {
            context.buffer.removeAll()
            return .payloadTooLarge
        }

        let requestLength = headerEnd + contentLength
        guard context.buffer.count >= requestLength else {
            return .needMoreData
        }

        let requestData = Data(context.buffer.prefix(requestLength))
        context.buffer.removeSubrange(0..<requestLength)
        return .request(requestData)
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
            processToolCall(id: id, params: params, connection: connection)
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

    private func processToolCall(id: Any?, params: [String: Any]?, connection: NWConnection) {
        guard let params = params,
              let toolName = params["name"] as? String else {
            sendHTTP(response: errorResponse(id: id, code: -32602, message: "Invalid params"), connection: connection)
            return
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch toolName {
        case "peek_ping":
            let response = handlePing(id: id, arguments: arguments)
            audit(tool: "peek_ping", ok: true)
            sendHTTP(response: response, connection: connection)
        case "camera_status":
            let response = handleCameraStatus(id: id, arguments: arguments)
            audit(tool: "camera_status", ok: true)
            sendHTTP(response: response, connection: connection)
        case "camera_snapshot":
            handleSnapshot(id: id, arguments: arguments, connection: connection)
        case "camera_start_recording":
            handleStartRecording(id: id, arguments: arguments, connection: connection)
        case "camera_stop_recording":
            handleStopRecording(id: id, arguments: arguments, connection: connection)
        case "camera_frames":
            handleFrames(id: id, arguments: arguments, connection: connection)
        default:
            audit(tool: toolName, ok: false, extras: ["error": "Tool not found"])
            sendHTTP(response: errorResponse(id: id, code: -32601, message: "Tool not found: \(toolName)"), connection: connection)
        }
    }

    // MARK: - Tool Handlers

    private func audit(tool: String, ok: Bool, extras: [String: Any] = [:]) {
        Logger.shared.log(tool: tool, ok: ok, extras: extras)
    }

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

    private func handleSnapshot(id: Any?, arguments: [String: Any], connection: NWConnection) {
        let quality: Camera.Quality
        do {
            quality = try parseQuality(arguments)
        } catch {
            audit(tool: "camera_snapshot", ok: false, extras: ["error": String(describing: error)])
            sendHTTP(response: toolErrorResponse(id: id, message: String(describing: error)), connection: connection)
            return
        }

        cameraWorkQueue.async {
            self.camera.takeSnapshot(quality: quality) { result in
                let response: [String: Any]
                switch result {
                case .success(let url):
                    let dimensions = self.imageDimensions(at: url) ?? (width: 1920, height: 1080)
                    self.audit(tool: "camera_snapshot", ok: true, extras: ["path": url.path])
                    response = self.toolResultResponse(id: id, payload: [
                        "ok": true,
                        "image_path": url.path,
                        "width": dimensions.width,
                        "height": dimensions.height
                    ])
                case .failure(let error):
                    self.audit(tool: "camera_snapshot", ok: false, extras: ["error": String(describing: error)])
                    response = self.toolErrorResponse(id: id, message: String(describing: error))
                }
                self.sendHTTP(response: response, connection: connection)
            }
        }
    }

    private func handleStartRecording(id: Any?, arguments: [String: Any], connection: NWConnection) {
        cameraWorkQueue.async {
            self.camera.startRecording { result in
                let response: [String: Any]
                switch result {
                case .success(let (recordingID, startedAt)):
                    self.audit(tool: "camera_start_recording", ok: true, extras: ["recording_id": recordingID.uuidString])
                    response = self.toolResultResponse(id: id, payload: [
                        "ok": true,
                        "recording_id": recordingID.uuidString,
                        "started_at": ISO8601DateFormatter().string(from: startedAt)
                    ])
                case .failure(let error):
                    self.audit(tool: "camera_start_recording", ok: false, extras: ["error": String(describing: error)])
                    response = self.toolErrorResponse(id: id, message: String(describing: error))
                }
                self.sendHTTP(response: response, connection: connection)
            }
        }
    }

    private func handleStopRecording(id: Any?, arguments: [String: Any], connection: NWConnection) {
        guard let recordingIDStr = arguments["recording_id"] as? String,
              let recordingID = UUID(uuidString: recordingIDStr) else {
            audit(tool: "camera_stop_recording", ok: false, extras: ["error": "Invalid recording_id"])
            sendHTTP(response: errorResponse(id: id, code: -32602, message: "Invalid recording_id"), connection: connection)
            return
        }

        cameraWorkQueue.async {
            self.camera.stopRecording(recordingID: recordingID) { result in
                let response: [String: Any]
                switch result {
                case .success(let (url, duration)):
                    self.audit(tool: "camera_stop_recording", ok: true, extras: ["path": url.path])
                    response = self.toolResultResponse(id: id, payload: [
                        "ok": true,
                        "video_path": url.path,
                        "duration_seconds": duration
                    ])
                case .failure(let error):
                    self.audit(tool: "camera_stop_recording", ok: false, extras: ["error": String(describing: error)])
                    response = self.toolErrorResponse(id: id, message: String(describing: error))
                }
                self.sendHTTP(response: response, connection: connection)
            }
        }
    }

    private func handleFrames(id: Any?, arguments: [String: Any], connection: NWConnection) {
        let count: Int
        let quality: Camera.Quality
        do {
            count = try parseFrameCount(arguments)
            quality = try parseQuality(arguments)
        } catch {
            audit(tool: "camera_frames", ok: false, extras: ["error": String(describing: error)])
            sendHTTP(response: toolErrorResponse(id: id, message: String(describing: error)), connection: connection)
            return
        }

        cameraWorkQueue.async {
            self.camera.captureFrames(count: count, quality: quality) { result in
                let response: [String: Any]
                switch result {
                case .success(let framesData):
                    let base64Frames = framesData.map { $0.base64EncodedString() }
                    self.audit(tool: "camera_frames", ok: true, extras: ["count": base64Frames.count])
                    response = self.toolResultResponse(id: id, payload: [
                        "ok": true,
                        "frames": base64Frames,
                        "count": base64Frames.count
                    ])
                case .failure(let error):
                    self.audit(tool: "camera_frames", ok: false, extras: ["error": String(describing: error)])
                    response = self.toolErrorResponse(id: id, message: String(describing: error))
                }
                self.sendHTTP(response: response, connection: connection)
            }
        }
    }

    private func parseQuality(_ arguments: [String: Any]) throws -> Camera.Quality {
        guard let value = arguments["quality"] else {
            return .medium
        }
        guard let qualityString = value as? String,
              let quality = Camera.Quality(rawValue: qualityString) else {
            throw PeekError.invalidArguments("quality must be one of: low, medium, high")
        }
        return quality
    }

    private func parseFrameCount(_ arguments: [String: Any]) throws -> Int {
        guard let value = arguments["count"] else {
            return 10
        }

        let count: Int
        if let intValue = value as? Int {
            count = intValue
        } else if let numberValue = value as? NSNumber, !(value is Bool) {
            let doubleValue = numberValue.doubleValue
            guard doubleValue.rounded(.towardZero) == doubleValue else {
                throw PeekError.invalidArguments("count must be an integer from 1 through 30")
            }
            count = numberValue.intValue
        } else {
            throw PeekError.invalidArguments("count must be an integer from 1 through 30")
        }

        guard (1...30).contains(count) else {
            throw PeekError.invalidArguments("count must be an integer from 1 through 30")
        }
        return count
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
        case 413: httpCode = "413 Payload Too Large"
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
}
