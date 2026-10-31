import Foundation

/// Appends timestamped lines to ~/Library/Logs/UsbAudioBridge/helper.log and stdout.
/// Past `maxBytes` the log moves to helper.log.1 (replacing the older one) and starts again.
enum Log {
    static let maxBytes = 1 << 20
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/UsbAudioBridge")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("helper.log")
    }()
    private static let queue = DispatchQueue(label: "log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            FileHandle.standardOutput.write(line.data(using: .utf8)!)
            append(line, to: url, maxBytes: maxBytes)
        }
    }

    static func append(_ line: String, to url: URL, maxBytes: Int) {
        let data = Data(line.utf8)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size > 0 && size + data.count > maxBytes {
            let previous = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
