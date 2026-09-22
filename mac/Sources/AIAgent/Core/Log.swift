import Foundation

/// 動作ログを ~/Library/Logs/AIAgent.log に追記する（不具合調査用）
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AIAgent.log")
    /// これを超えたら古いログを1世代だけ残して新しく書き始める（容量が増え続けないように）
    private static let maxBytes = 1_000_000
    private static let queue = DispatchQueue(label: "AIAgent.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let old = url.appendingPathExtension("old")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
