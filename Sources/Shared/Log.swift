//  Log.swift — a plain text log plus an in-memory tail the menu can show.

import Foundation

public enum Log {
    public static let fileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SidecarReconnect.log")

    private static let queue = DispatchQueue(label: "sidecar.log")
    private static var recent: [String] = []
    private static let recentLimit = 60

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func write(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)"
        queue.async {
            recent.append(line)
            if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }

            let url = fileURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    public static func tail(_ count: Int = 20) -> [String] {
        queue.sync { Array(recent.suffix(count)) }
    }

    /// Keeps the file from growing without bound over months of daily wakes.
    public static func trimIfLarge(maxBytes: Int = 512_000) {
        queue.async {
            guard let size = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? Int,
                size > maxBytes,
                let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
            let kept = text.split(separator: "\n").suffix(1000).joined(separator: "\n")
            try? (kept + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
