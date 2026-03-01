import Foundation

/// Thin wrapper around the embedded `blueutil` binary.
/// All operations run synchronously on the calling thread — always call from a background queue.
enum Blueutil {
    private static let url: URL? = Bundle.main.resourceURL?.appendingPathComponent("blueutil")

    static func isConnected(_ address: String) -> Bool {
        output(["--is-connected", address]) == "1"
    }

    @discardableResult
    static func run(_ args: [String]) -> Int32 {
        guard let url else {
            log.error("blueutil: binary not found in bundle")
            return -1
        }
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.standardOutput = Pipe()
        let errPipe = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch {
            log.error("blueutil \(args.joined(separator: " ")): launch failed \(error)")
            return -1
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.error("blueutil \(args.joined(separator: " ")) failed: exit=\(p.terminationStatus) \(stderr)")
        }
        return p.terminationStatus
    }

    private static func output(_ args: [String]) -> String {
        guard let url else {
            log.error("blueutil: binary not found in bundle")
            return ""
        }
        let p = Process()
        p.executableURL = url
        p.arguments = args
        let pipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = pipe
        p.standardError = errPipe
        do { try p.run() } catch {
            log.error("blueutil output \(args.joined(separator: " ")): launch failed \(error)")
            return ""
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.error("blueutil output \(args.joined(separator: " ")): exit=\(p.terminationStatus) stderr=\(stderr)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
