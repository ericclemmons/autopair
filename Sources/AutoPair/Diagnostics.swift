import Foundation

enum Diagnostics {
    private static let queue = DispatchQueue(label: "com.ericclemmons.AutoPair.diagnostics")
    private static let formatter = ISO8601DateFormatter()
    private static let maximumBytes = 256_000

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first!
        return base.appendingPathComponent("AutoPair", isDirectory: true)
            .appendingPathComponent("diagnostics.log")
    }

    static func record(_ message: String) {
        log.info("\(message, privacy: .public)")
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attributes[.size] as? NSNumber)?.intValue ?? 0 > maximumBytes {
                trim(url)
            }
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Keeps the newest half so a long retry loop cannot erase the events that started it.
    private static func trim(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            try? Data().write(to: url)
            return
        }
        var kept = data.suffix(maximumBytes / 2)
        if let newline = kept.firstIndex(of: UInt8(ascii: "\n")) {
            kept = kept[kept.index(after: newline)...]
        }
        try? Data(kept).write(to: url, options: .atomic)
    }

    static func contents(maxBytes: Int? = nil) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return "No diagnostics yet." }
            let selected = maxBytes.map { Data(data.suffix($0)) } ?? data
            return String(decoding: selected, as: UTF8.self)
        }
    }
}
