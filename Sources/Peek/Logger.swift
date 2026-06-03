import Foundation

final class Logger {
    static let shared = Logger()

    private let logURL: URL
    private let queue = DispatchQueue(label: "com.peek.logger")

    private init() {
        guard let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs")
            .appendingPathComponent("Peek") else {
            logURL = URL(fileURLWithPath: "/tmp/Peek/captures.log")
            return
        }
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
            do {
                let data = try JSONSerialization.data(withJSONObject: entry)
                guard let line = String(data: data, encoding: .utf8) else { return }
                let lineWithNewline = line + "\n"
                guard let lineData = lineWithNewline.data(using: .utf8) else { return }
                if FileManager.default.fileExists(atPath: self.logURL.path),
                   let handle = FileHandle(forWritingAtPath: self.logURL.path) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: lineData)
                } else {
                    try lineData.write(to: self.logURL, options: [.atomic])
                }
            } catch {
                // Silently ignore logging errors
            }
        }
    }
}
