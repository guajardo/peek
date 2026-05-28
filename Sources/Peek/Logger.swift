import Foundation

final class Logger {
    static let shared = Logger()

    private let logURL: URL
    private let queue = DispatchQueue(label: "com.peek.logger")

    private init() {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
            .appendingPathComponent("Peek")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        logURL = logDir.appendingPathComponent("captures.log")
    }

    func log(tool: String, ok: Bool, extras: [String: Any] = [:]) {
        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "tool": tool,
            "ok": ok
        ]
        for (k, v) in extras {
            entry[k] = v
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? JSONSerialization.data(withJSONObject: entry),
               let line = String(data: data, encoding: .utf8) {
                let lineWithNewline = line + "\n"
                if let lineData = lineWithNewline.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: self.logURL.path) {
                        if let handle = FileHandle(forWritingAtPath: self.logURL.path) {
                            handle.seekToEndOfFile()
                            handle.write(lineData)
                            handle.closeFile()
                        }
                    } else {
                        try? lineData.write(to: self.logURL)
                    }
                }
            }
        }
    }
}
