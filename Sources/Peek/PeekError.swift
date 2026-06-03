import Foundation

enum PeekError: Error, CustomStringConvertible {
    case cameraNotAvailable
    case permissionDenied
    case cameraBusy
    case encodingFailed
    case invalidRecordingID
    case invalidArguments(String)
    case serverNotRunning

    var description: String {
        switch self {
        case .cameraNotAvailable:
            return "Camera not available"
        case .permissionDenied:
            return "Camera permission denied"
        case .cameraBusy:
            return "Camera is busy"
        case .encodingFailed:
            return "Failed to encode media"
        case .invalidRecordingID:
            return "Invalid recording ID"
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        case .serverNotRunning:
            return "Server not running"
        }
    }
}
