import Foundation
import AppKit
import Domain
import Support

/// Arms tonight's wake, fires the run when the time comes (AC only), keeps the Mac awake through
/// the helper with heartbeats, and re-arms. Lives as long as the app process.
public actor OvernightScheduler {
    public struct Config: Sendable, Equatable {
        public var enabled: Bool
        public var hour: Int
        public var minute: Int
        public var catchUp: Bool
        /// Daytime reads: every hour (h1), every three (h3), or only at night (off). Idle + AC only.
        public var daytime: String
        public init(enabled: Bool = true, hour: Int = 3, minute: Int = 0, catchUp: Bool = true, daytime: String = "h1") { self.enabled = enabled; self.hour = hour; self.minute = minute; self.catchUp = catchUp; self.daytime = daytime }
        public var daytimeInterval: TimeInterval? { daytime == "h1" ? 3600 : (daytime == "h3" ? 3 * 3600 : nil) }
        public static let idleMinutesForDaytime = 10
        public static func parse(_ s: String?) -> (Int, Int) {
            let p = (s ?? "03:00").split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? (p[0], p[1]) : (3, 0)
        }
    }

    public typealias RunBlock = @Sendable (RunTrigger) async -> RunOutcome

    private let helper = WakeHelper.Client()
    private let log = Log("scheduler")
    private let run: RunBlock
    private let store: any RunStore
    private var loop: Task<Void, Never>?
    private var dayLoop: Task<Void, Never>?
    private var config = Config()
    /// The app tells the scheduler when any run happens, so daytime reads count from the last one.
    public private(set) var lastRunAt: Date?
    public func noteRun(at d: Date) { lastRunAt = d }
    private var lastFiredNight: String?

    public init(store: any RunStore, run: @escaping RunBlock) { self.store = store; self.run = run }

    public func start(_ c: Config) {
        config = c
        loop?.cancel(); dayLoop?.cancel()
        if c.daytimeInterval != nil { dayLoop = Task { await self.daytimeLoop() } }
        guard c.enabled else { try? helper.cancelWakes(); log.info("disabled"); return }
        loop = Task { await self.mainLoop() }
    }

    public func stop() { loop?.cancel(); dayLoop?.cancel(); try? helper.cancelWakes() }

    /// Between 7 AM and midnight: when the last run is older than the interval, the Mac is on power and
    /// nobody has touched it for ten minutes, read what's new. Checked once a minute.
    private func daytimeLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let interval = config.daytimeInterval else { return }
            let hour = Calendar.current.component(.hour, from: Date())
            guard hour >= 7, hour < 24, PowerState.isOnAC, PowerState.idleSeconds >= Double(Config.idleMinutesForDaytime * 60) else { continue }
            guard Date().timeIntervalSince(lastRunAt ?? .distantPast) >= interval else { continue }
            log.info("daytime read (idle \(Int(PowerState.idleSeconds / 60)) min)")
            lastRunAt = Date()
            let outcome = await run(.daytime)
            log.info("daytime outcome: \(outcome)")
        }
    }

    public func nextFire(from now: Date = Date()) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = config.hour; comps.minute = config.minute; comps.second = 0
        var d = Calendar.current.date(from: comps)!
        if d <= now { d = Calendar.current.date(byAdding: .day, value: 1, to: d)! }
        return d
    }

    private func mainLoop() async {
        while !Task.isCancelled {
            let fire = nextFire()
            do { try helper.arm(at: fire.addingTimeInterval(-30)); log.info("armed wake for \(fire)") }
            catch { log.warn("helper unavailable (\(error)); the Mac must be awake at \(fire) for the run to happen") }
            let wait = max(1, fire.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            if Task.isCancelled { return }
            await fireNow(trigger: .overnight)
        }
    }

    /// The nightly fire. Skips honestly when not on AC.
    public func fireNow(trigger: RunTrigger) async {
        guard PowerState.isOnAC else {
            log.warn("skipped: on battery"); try? await store.setValue("overnight.lastSkip", "onBattery"); return
        }
        var lease: String?
        do { lease = try helper.beginAwake() } catch { log.warn("no helper lease: \(error)") }
        let assertion = PowerState.Assertion(reason: "Brownie overnight run")
        let beat = Task { [helper] in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 60_000_000_000); if let lease { try? helper.heartbeat(lease) } }
        }
        let outcome = await run(trigger)
        beat.cancel()
        if let lease { try? helper.endAwake(lease) }
        _ = assertion
        lastFiredNight = ISO8601DateFormatter().string(from: Date())
        log.info("overnight outcome: \(outcome)")
    }

    /// Arms a wake two minutes out and runs a tiny dry run when it fires, so the helper can be
    /// verified on day one without waiting for 3 AM.
    public func testWake() async -> String {
        let at = Date().addingTimeInterval(120)
        do { try helper.arm(at: at) } catch { return "The wake helper isn't running (\(error)). Press Allow in Settings → Overnight first." }
        log.info("test wake armed for \(at)")
        Task { try? await Task.sleep(nanoseconds: 125_000_000_000); await self.fireNow(trigger: .test); try? self.helper.arm(at: self.nextFire().addingTimeInterval(-30)) }
        return "Armed. Close the lid now; the Mac wakes in 2 minutes, runs a short read, and re-arms 3 AM. Check Settings → Overnight → Health afterwards."
    }

    /// Called on wake/launch: if last night's fire was missed and catch-up is on, run when plugged in.
    public func catchUpIfNeeded(lastRun: RunRecord?) async {
        guard config.enabled, config.catchUp else { return }
        let lastFire = nextFire().addingTimeInterval(-86400)
        let ranSince = (lastRun?.startedAt ?? .distantPast) >= lastFire
        guard !ranSince, PowerState.isOnAC else { return }
        // Wait until the user has been idle for 20 minutes so the catch-up never competes with them.
        while PowerState.idleSeconds < 20 * 60 {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if !PowerState.isOnAC || Task.isCancelled { return }
        }
        log.info("catch-up run (idle \(Int(PowerState.idleSeconds / 60)) min)")
        await fireNow(trigger: .catchUp)
    }

    // MARK: login item

    public static func setLoginItem(_ on: Bool) {
        // SwiftPM dev build: register via a per-user LaunchAgent that opens the binary at login.
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/app.brownie.login.plist")
        if on {
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Label</key><string>app.brownie.login</string><key>ProgramArguments</key><array><string>\(exe)</string></array><key>RunAtLoad</key><true/></dict></plist>"
            try? xml.write(to: plist, atomically: true, encoding: .utf8)
        } else { try? FileManager.default.removeItem(at: plist) }
    }
    public static var isLoginItem: Bool { FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/app.brownie.login.plist").path) }
}
