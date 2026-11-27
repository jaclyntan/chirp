import AppKit
import Darwin
import Foundation
import OSLog

// MARK: - Diagnostics
//
// Chirp's own on-disk record, in ~/Library/Application Support/Chirp/diagnostics/.
//
// The unified log alone wasn't enough. On a Mac under heavy load it rotates
// within hours. Investigating freezes and lost dictations found only the
// current afternoon still there, so last week's crashes were unrecoverable,
// and nothing in it said what the system was doing at the time.
//
// What lands here, per day, kept for 14 days:
// - every `.notice` / `.error` line from `dictationLog`, with the same
//   redaction as the unified log (transcripts never appear),
// - a header per launch: version, macOS, settings, pending recordings,
// - a system snapshot at launch, at each recording stop, and on every
//   timeout or stall: memory pressure, swap, load, thermal, own footprint,
// - whether the previous session quit cleanly, plus a copy of any crash
//   report macOS wrote for it,
// - a `sample` of every thread when the main thread freezes for 3 s+.
//
// Only the app writes here. The CLI modes (`--selftest` and friends) don't,
// so test runs never pollute the record.

/// Privacy for `LogLine` interpolations, mirroring `OSLogPrivacy`: strings
/// and arbitrary values are private unless marked `.public`; numbers and
/// booleans are public.
enum LogPrivacy {
    case `public`, `private`
}

/// Mirrors the one `OSLogFloatFormatting` form the codebase uses.
enum LogFloatFormat {
    case fixed(precision: Int)
}

/// A log message built with the same interpolation syntax as `Logger`
/// (`privacy:`, `format: .fixed(precision:)`), rendered once to a string
/// with private values already redacted, so it can go to both the unified
/// log and the diagnostics file.
struct LogLine: ExpressibleByStringInterpolation {
    let text: String

    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        mutating func appendLiteral(_ literal: String) { text += literal }

        mutating func appendInterpolation(_ value: String, privacy: LogPrivacy = .private) {
            text += privacy == .public ? value : "<private>"
        }

        mutating func appendInterpolation<T: BinaryInteger>(_ value: T, privacy: LogPrivacy = .public) {
            text += privacy == .public ? String(value) : "<private>"
        }

        mutating func appendInterpolation(_ value: Bool, privacy: LogPrivacy = .public) {
            text += privacy == .public ? String(value) : "<private>"
        }

        mutating func appendInterpolation<T: BinaryFloatingPoint>(
            _ value: T, format: LogFloatFormat? = nil, privacy: LogPrivacy = .public
        ) {
            guard privacy == .public else { text += "<private>"; return }
            switch format {
            case .fixed(let precision)?: text += String(format: "%.\(precision)f", Double(value))
            case nil: text += String(describing: Double(value))
            }
        }

        mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .private) {
            text += privacy == .public ? String(describing: value) : "<private>"
        }
    }
}

/// `Logger`'s interface, writing to the unified log and — for `.notice`
/// and above — to the diagnostics file too.
struct ChirpLogger: Sendable {
    let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: "local.chirp", category: category)
    }

    func debug(_ line: LogLine) { logger.debug("\(line.text, privacy: .public)") }
    func info(_ line: LogLine) { logger.info("\(line.text, privacy: .public)") }

    func notice(_ line: LogLine) {
        logger.notice("\(line.text, privacy: .public)")
        Diagnostics.shared.record("notice", category, line.text)
    }

    func error(_ line: LogLine) {
        logger.error("\(line.text, privacy: .public)")
        Diagnostics.shared.record("ERROR", category, line.text)
    }

    func fault(_ line: LogLine) {
        logger.fault("\(line.text, privacy: .public)")
        Diagnostics.shared.record("FAULT", category, line.text)
    }
}

final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    static let retentionDays = 14
    /// At most one thread sample per this interval: sampling costs a couple
    /// of seconds of CPU, which is the last thing a struggling Mac needs.
    static let sampleInterval: TimeInterval = 10 * 60

    let directory: URL
    private let queue = DispatchQueue(label: "local.chirp.diagnostics", qos: .utility)

    // Everything below is confined to `queue`.
    private var enabled = false
    private var handle: FileHandle?
    private var handleDay: String?
    private var lastSampleAt: Date?

    private let pid = ProcessInfo.processInfo.processIdentifier

    init(directory: URL = AppPaths.supportDirectory.appendingPathComponent("diagnostics", isDirectory: true)) {
        self.directory = directory
    }

    private var markerURL: URL { directory.appendingPathComponent("session-running.json") }

    private struct SessionMarker: Codable {
        let pid: Int32
        let launchedAt: Date
        let version: String
    }

    // MARK: Session lifecycle

    /// Starts recording to disk for this app session. Call once at launch.
    func startSession(settings: [(String, String)], pendingRecordings: Int) {
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            enabled = true
            prune()

            let info = Bundle.main.infoDictionary ?? [:]
            let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") "
                + "(\(info["CFBundleVersion"] as? String ?? "?"))"
            let process = ProcessInfo.processInfo
            write("==== launch: Chirp \(version), pid \(pid)")
            let os = process.operatingSystemVersion
            write("     macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) "
                  + "(\(Self.sysctlString("kern.osversion") ?? "?")), "
                  + "\(Self.sysctlString("hw.model") ?? "unknown Mac"), "
                  + "\(process.physicalMemory / 1_073_741_824) GB RAM, "
                  + "up \(Self.uptime().map(Self.formatDuration) ?? "?")")
            write("     settings: " + settings.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
            write("     pending recordings: \(pendingRecordings)")
            write("     " + Self.systemSnapshot())

            reportPreviousSessionIfUnclean()
            let marker = SessionMarker(pid: pid, launchedAt: Date(), version: version)
            try? JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
        }
    }

    /// Marks the session as cleanly ended and flushes. Blocks until done:
    /// it runs right before `_exit`.
    func endSession() {
        queue.sync {
            guard enabled else { return }
            write("==== quit (clean)")
            try? FileManager.default.removeItem(at: markerURL)
            try? handle?.close()
            handle = nil
            enabled = false
        }
    }

    // MARK: Recording

    func record(_ level: String, _ category: String, _ text: String) {
        queue.async { [self] in
            write("\(Self.pad(level, 6)) \(Self.pad(category, 9)) \(text)")
        }
    }

    /// One `system:` line describing the machine right now.
    func snapshot(_ reason: String) {
        queue.async { [self] in
            write("\(Self.pad("system", 6)) \(Self.pad(reason, 9)) \(Self.systemSnapshot())")
        }
    }

    /// Records every thread's stack for two seconds with `/usr/bin/sample`,
    /// so a freeze leaves behind what the main thread was stuck in. Works
    /// because the app isn't built with the hardened runtime; rate-limited.
    func captureThreadSample(reason: String) {
        queue.async { [self] in
            guard enabled else { return }
            if let lastSampleAt, Date().timeIntervalSince(lastSampleAt) < Self.sampleInterval {
                write("sample skipped (one taken in the last \(Int(Self.sampleInterval / 60)) min): \(reason)")
                return
            }
            lastSampleAt = Date()
            let file = directory.appendingPathComponent("sample-\(Self.fileStamp(Date())).txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(pid), "2", "-mayDie", "-file", file.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                write("sample  started (\(reason)) -> \(file.lastPathComponent)")
            } catch {
                write("sample  failed to start: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Internals (on `queue`)

    private func write(_ line: String) {
        guard enabled else { return }
        let now = Date()
        let day = Self.dayStamp(now)
        if handleDay != day || handle == nil {
            try? handle?.close()
            let url = directory.appendingPathComponent("chirp-\(day).log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            handleDay = day
        }
        // Unbuffered: each line is a write(2), so a crash right after still
        // leaves it on disk.
        let text = "\(Self.timeStamp(now)) [\(pid)] \(line)\n"
        try? handle?.write(contentsOf: Data(text.utf8))
    }

    /// The marker is removed on a clean quit, so finding it at launch means
    /// the last session crashed, was force-quit, or the Mac lost power.
    private func reportPreviousSessionIfUnclean() {
        guard let data = try? Data(contentsOf: markerURL),
              let previous = try? JSONDecoder().decode(SessionMarker.self, from: data) else { return }
        write("ERROR  previous session (pid \(previous.pid), Chirp \(previous.version), launched "
              + "\(Self.timeStamp(previous.launchedAt, withDate: true))) did not quit cleanly")
        let reports = crashReports(since: previous.launchedAt)
        if reports.isEmpty {
            write("       no crash report for it: most likely force-quit, killed, or a hang")
        }
        for report in reports {
            let copy = directory.appendingPathComponent("crash-\(report.lastPathComponent)")
            try? FileManager.default.copyItem(at: report, to: copy)
            write("       crash report: \(report.path) (copied as \(copy.lastPathComponent))")
        }
    }

    private func crashReports(since date: Date) -> [URL] {
        let folders = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        ]
        return folders.flatMap { folder -> [URL] in
            let items = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return items.filter { url in
                url.lastPathComponent.hasPrefix("Chirp")
                    && ((try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast) >= date
            }
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 24 * 3600)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in items where url != markerURL {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: System state

    static func systemSnapshot() -> String {
        var parts: [String] = []

        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            let name = [1: "normal", 2: "warning", 4: "critical"][Int(level)] ?? "level \(level)"
            parts.append("pressure=\(name)")
        }

        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            parts.append(String(format: "swap=%.1f/%.1f GB",
                                Double(swap.xsu_used) / 1_073_741_824,
                                Double(swap.xsu_total) / 1_073_741_824))
        }

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            parts.append(String(format: "load=%.0f/%.0f/%.0f", loads[0], loads[1], loads[2]))
        }

        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        parts.append("thermal=\(thermal)")

        if let footprint = ownFootprint() {
            parts.append("chirp=\(footprint / 1_048_576) MB")
        }
        return parts.joined(separator: " ")
    }

    private static func ownFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Wall-clock time since boot, sleep included. `systemUptime` excludes
    /// sleep, so a laptop up for two weeks could report hours.
    private static func uptime() -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
    }

    // MARK: Formatting

    /// Right-pads to a column width without ever truncating.
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func dayStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func timeStamp(_ date: Date, withDate: Bool = false) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let time = String(format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
                          (c.nanosecond ?? 0) / 1_000_000)
        return withDate ? "\(dayStamp(date)) \(time)" : time
    }

    private static func fileStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return dayStamp(date) + String(format: "-%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86_400
        let hours = Int(seconds) % 86_400 / 3600
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(Int(seconds) % 3600 / 60)m"
    }

    // MARK: Self-test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ value: Bool, _ label: String) {
            if !value { passed = false }
            print("\(value ? "PASS" : "FAIL"): \(label)")
        }
        let secret = "my dictated words"
        let number = 42
        let seconds = 1.2345
        let line: LogLine = "a \(secret) b \(secret, privacy: .public) n=\(number) t=\(seconds, format: .fixed(precision: 1))"
        check(line.text == "a <private> b my dictated words n=42 t=1.2", "log lines redact private strings like os_log")

        let snapshot = systemSnapshot()
        check(snapshot.contains("pressure=") && snapshot.contains("swap=") && snapshot.contains("chirp="),
              "system snapshot reports pressure, swap and footprint")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-diag-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Diagnostics(directory: directory)
        first.startSession(settings: [("k", "v")], pendingRecordings: 0)
        first.record("notice", "test", "hello")
        first.queue.sync {}
        // No endSession: as if it crashed.
        let second = Diagnostics(directory: directory)
        second.startSession(settings: [], pendingRecordings: 0)
        second.endSession()
        let logs = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let text = logs.filter { $0.hasSuffix(".log") }
            .compactMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        check(text.contains("test      hello"), "notice lines reach the diagnostics file")
        check(text.contains("did not quit cleanly"), "an unclean previous session is reported at launch")
        check(text.contains("==== quit (clean)") && !logs.contains("session-running.json"),
              "a clean quit clears the session marker")

        // The real `/usr/bin/sample`, pointed at this test process.
        let sampler = Diagnostics(directory: directory)
        sampler.startSession(settings: [], pendingRecordings: 0)
        sampler.captureThreadSample(reason: "self-test")
        var sampled = false
        for _ in 0..<150 where !sampled {
            Thread.sleep(forTimeInterval: 0.1)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            sampled = names.contains { name in
                name.hasPrefix("sample-") && ((try? String(
                    contentsOf: directory.appendingPathComponent(name), encoding: .utf8))?
                    .contains("Call graph") ?? false)
            }
        }
        check(sampled, "a stall sample captures every thread's stack")
        sampler.captureThreadSample(reason: "self-test again")
        sampler.endSession()
        let after = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("sample-") }
        check(after.count == 1, "thread samples are rate-limited")
        return passed
    }
}
