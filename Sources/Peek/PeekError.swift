import Foundation

enum PeekError: Error, CustomStringConvertible {
    case cameraNotAvailable
    case cameraBusy
    case encodingFailed
    case invalidArguments(String)

    var description: String {
        switch self {
        case .cameraNotAvailable:
            return "Camera not available"
        case .cameraBusy:
            return "Camera is busy"
        case .encodingFailed:
            return "Failed to encode media"
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        }
    }
}
