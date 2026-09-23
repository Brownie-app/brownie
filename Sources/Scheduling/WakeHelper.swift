import Foundation
import Support

/// The only root code. A launchd daemon running this same binary with `--wake-helper`, talking over
/// a Unix socket owned by the user (mode 0600). Six ops; a deadman timer releases `disablesleep`
/// if the app stops feeding heartbeats. See docs/spec/08-overnight.md.
///
/// Dev-build note: a shipping build replaces the socket with an XPC service registered through
/// SMAppService and gates the connection on the client's code-signing requirement.
public enum WakeHelper {
    public static let socketPath = "/var/run/brownie-wake.sock"
    public static let label = "app.brownie.wakehelper"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    public static let logPath = "/Library/Logs/Brownie-wakehelper.log"
    static let heartbeatTimeout: TimeInterval = 180

    // MARK: daemon side

    public static func runDaemon() -> Never {
        let d = Daemon(); d.run()
    }

    final class Daemon {
        private var lease: String?
        private var lastBeat = Date()
        private let queue = DispatchQueue(label: "wakehelper")

        func run() -> Never {
            log("helper starting; resetting disablesleep")
            _ = shell("/usr/bin/pmset", ["disablesleep", "0"])
            unlink(WakeHelper.socketPath)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &addr.sun_path) { p in _ = WakeHelper.socketPath.withCString { strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), $0, 103) } }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }) == 0 else { log("bind failed \(errno)"); exit(1) }
            if let uid = ProcessInfo.processInfo.environment["BROWNIE_UID"].flatMap(UInt32.init) { chown(WakeHelper.socketPath, uid_t(uid), 0) }
            chmod(WakeHelper.socketPath, 0o600)
            listen(fd, 4)
            queue.asyncAfter(deadline: .now() + 30) { self.deadman() }
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { continue }
                var buf = [UInt8](repeating: 0, count: 512)
                let n = read(c, &buf, 511)
                let line = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let reply = queue.sync { handle(line) }
                _ = reply.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
        }

        private func deadman() {
            if lease != nil, Date().timeIntervalSince(lastBeat) > WakeHelper.heartbeatTimeout {
                log("deadman: no heartbeat for \(Int(WakeHelper.heartbeatTimeout))s — releasing sleep")
                _ = shell("/usr/bin/pmset", ["disablesleep", "0"]); lease = nil
            }
            queue.asyncAfter(deadline: .now() + 30) { self.deadman() }
        }

        private func handle(_ line: String) -> String {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            switch parts.first {
            case "ping": return "ok\n"
            case "arm":
                guard parts.count > 1 else { return "err args\n" }
                _ = shell("/usr/bin/pmset", ["schedule", "cancelall"])
                let rc = shell("/usr/bin/pmset", ["schedule", "wake", parts[1]])
                log("arm wake \(parts[1]) rc=\(rc)"); return rc == 0 ? "ok\n" : "err pmset \(rc)\n"
            case "cancel": _ = shell("/usr/bin/pmset", ["schedule", "cancelall"]); log("cancelled wakes"); return "ok\n"
            case "begin":
                let id = UUID().uuidString; lease = id; lastBeat = Date()
                _ = shell("/usr/bin/pmset", ["disablesleep", "1"]); log("begin awake \(id)"); return "ok \(id)\n"
            case "heartbeat":
                guard parts.count > 1, parts[1] == lease else { return "err lease\n" }
                lastBeat = Date(); return "ok\n"
            case "end":
                guard parts.count > 1, parts[1] == lease else { return "err lease\n" }
                _ = shell("/usr/bin/pmset", ["disablesleep", "0"]); lease = nil; log("end awake"); return "ok\n"
            default: return "err unknown\n"
            }
        }

        private func shell(_ path: String, _ args: [String]) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
        }

        private func log(_ s: String) {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
            if let h = FileHandle(forWritingAtPath: WakeHelper.logPath) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
            else { FileManager.default.createFile(atPath: WakeHelper.logPath, contents: Data(line.utf8)) }
        }
    }

    // MARK: client side

    public struct Client: Sendable {
        private let log = Log("wake.client")
        public init() {}

        public var isInstalled: Bool { FileManager.default.fileExists(atPath: WakeHelper.plistPath) }
        public func ping() -> Bool { (try? send("ping"))?.hasPrefix("ok") ?? false }

        public func arm(at date: Date) throws {
            let f = DateFormatter(); f.dateFormat = "MM/dd/yy HH:mm:ss"; f.timeZone = .current
            try expectOK(send("arm \(f.string(from: date))"))
        }
        public func cancelWakes() throws { try expectOK(send("cancel")) }
        public func beginAwake() throws -> String {
            let r = try send("begin"); try expectOK(r)
            return String(r.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        public func heartbeat(_ lease: String) throws { try expectOK(send("heartbeat \(lease)")) }
        public func endAwake(_ lease: String) throws { try expectOK(send("end \(lease)")) }

        private func expectOK(_ r: String) throws { guard r.hasPrefix("ok") else { throw Error.helper(r.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        public enum Error: Swift.Error { case notRunning, helper(String) }

        private func send(_ line: String) throws -> String {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &addr.sun_path) { p in _ = WakeHelper.socketPath.withCString { strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), $0, 103) } }
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
            guard ok else { throw Error.notRunning }
            _ = (line + "\n").withCString { write(fd, $0, strlen($0)) }
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(fd, &buf, 255)
            return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
        }

        /// Installs the launchd daemon (one admin prompt). `executable` is this app's binary.
        public func install(executable: String) throws {
            let uid = getuid()
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>\(WakeHelper.label)</string>
              <key>ProgramArguments</key><array><string>\(executable)</string><string>--wake-helper</string></array>
              <key>EnvironmentVariables</key><dict><key>BROWNIE_UID</key><string>\(uid)</string></dict>
              <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
              <key>StandardErrorPath</key><string>\(WakeHelper.logPath)</string>
            </dict></plist>
            """
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("brownie-wake.plist")
            try plist.write(to: tmp, atomically: true, encoding: .utf8)
            let script = "cp '\(tmp.path)' '\(WakeHelper.plistPath)' && chown root:wheel '\(WakeHelper.plistPath)' && chmod 644 '\(WakeHelper.plistPath)' && launchctl bootout system '\(WakeHelper.plistPath)' 2>/dev/null; launchctl bootstrap system '\(WakeHelper.plistPath)'"
            try runAsAdmin(script)
            log.info("wake helper installed")
        }

        public func uninstall() throws {
            try runAsAdmin("launchctl bootout system '\(WakeHelper.plistPath)' 2>/dev/null; rm -f '\(WakeHelper.plistPath)' '\(WakeHelper.socketPath)'; /usr/bin/pmset disablesleep 0; /usr/bin/pmset schedule cancelall")
        }

        private func runAsAdmin(_ shellScript: String) throws {
            let esc = shellScript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"\(esc)\" with administrator privileges"]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw Error.helper("admin install failed (\(p.terminationStatus))") }
        }
    }
}
