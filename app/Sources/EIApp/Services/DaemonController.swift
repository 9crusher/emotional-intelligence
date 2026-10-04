import AppKit
import AVFoundation
import Foundation
import Observation

/// Runs `ei-daemon` as a child process. The daemon is the only thing that touches the camera
/// and the models; this app just starts/stops it and shows its log. Because the app is the
/// responsible process, the daemon uses the app's camera permission.
@Observable @MainActor
final class DaemonController {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case external(pid: Int32)  // a daemon this app didn't start (terminal, launchd)
        case failed(String)
    }

    var status: Status = .stopped
    var log: [String] = []

    var isRunning: Bool {
        switch status {
        case .running, .starting, .external: true
        default: false
        }
    }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var recentCrashes: [Date] = []
    @ObservationIgnored private var partialLine = ""

    private let maxLogLines = 500

    // MARK: Preferences (UserDefaults; app-only, not shared with Python)

    static let defaultRepoPath =
        Bundle.main.object(forInfoDictionaryKey: "EIRepoPath") as? String
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "git/emotional-intelligence").path

    var repoPath: String {
        get { UserDefaults.standard.string(forKey: "repoPath") ?? Self.defaultRepoPath }
        set { UserDefaults.standard.set(newValue, forKey: "repoPath") }
    }

    var uvPathOverride: String {
        get { UserDefaults.standard.string(forKey: "uvPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "uvPath") }
    }

    var fakeMode: Bool {
        get { UserDefaults.standard.bool(forKey: "fakeMode") }
        set { UserDefaults.standard.set(newValue, forKey: "fakeMode") }
    }

    // MARK: Lifecycle

    /// Starts the daemon unless one is already running (e.g. from a terminal).
    func start(knownState: DaemonState?) {
        guard process == nil else { return }
        if let pid = knownState?.pid, kill(pid, 0) == 0 {
            status = .external(pid: pid)
            append("Another ei-daemon is already running (pid \(pid)); not starting a second one.")
            return
        }
        stopping = false
        status = .starting
        requestCameraThen { [weak self] in self?.launch() }
    }

    func stop() {
        stopping = true
        if let process, process.isRunning {
            process.terminate()  // SIGTERM; the daemon closes the camera and exits
        }
        if case .external = status { status = .stopped }
    }

    func restart(knownState: DaemonState?) {
        stop()
        Task {
            for _ in 0..<50 where process != nil { try? await Task.sleep(for: .milliseconds(100)) }
            start(knownState: nil)
        }
    }

    /// Blocking stop for app termination.
    func stopAndWait() {
        stopping = true
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: Internals

    private func requestCameraThen(_ next: @escaping @MainActor () -> Void) {
        if fakeMode || AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            next()
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                if !granted { self.append("Camera access denied; captures will fail until it is granted in System Settings.") }
                next()
            }
        }
    }

    private func launch() {
        guard let (exe, args) = EICLI.command("ei-daemon", repoPath: repoPath, uvOverride: uvPathOverride) else {
            status = .failed("Can't find ei-daemon. Run `uv sync` in \(repoPath) or set the uv path.")
            append("ERROR: no .venv/bin/ei-daemon and no uv found")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args + (fakeMode ? ["--fake"] : [])
        p.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        var env = EICLI.environment()
        env["EI_EXIT_WITH_PARENT"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.didExit(code: code) }
        }
        do {
            append("$ \(([exe] + (p.arguments ?? [])).joined(separator: " "))")
            try p.run()
            process = p
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
            append("ERROR: \(error.localizedDescription)")
        }
    }

    private func didExit(code: Int32) {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        append("ei-daemon exited (status \(code))")
        if stopping {
            status = .stopped
            return
        }
        // Unexpected exit: restart with backoff, at most 3 times a minute.
        let now = Date()
        recentCrashes = recentCrashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard recentCrashes.count <= 3 else {
            status = .failed("ei-daemon keeps exiting (status \(code)). See Settings → Diagnostics.")
            return
        }
        status = .starting
        Task {
            try? await Task.sleep(for: .seconds(Double(recentCrashes.count) * 2))
            if !stopping { launch() }
        }
    }

    private func ingest(_ text: String) {
        let combined = partialLine + text
        var lines = combined.components(separatedBy: "\n")
        partialLine = lines.removeLast()
        lines.filter { !$0.isEmpty }.forEach(append)
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > maxLogLines { log.removeFirst(log.count - maxLogLines) }
    }
}

/// Locates and runs the Python entry points from the repo (`.venv/bin/<name>`, else `uv run`).
enum EICLI {
    static func command(_ name: String, repoPath: String, uvOverride: String) -> (String, [String])? {
        let venv = (repoPath as NSString).appendingPathComponent(".venv/bin/\(name)")
        if FileManager.default.isExecutableFile(atPath: venv) { return (venv, []) }
        guard let uv = uvPath(override: uvOverride) else { return nil }
        return (uv, ["run", "--project", repoPath, name])
    }

    static func uvPath(override: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [override, "\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                          "\(home)/.cargo/bin/uv"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// GUI apps get a minimal PATH; add the usual tool locations and unbuffer Python output.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// Runs `ei <args>` and returns (exit status, combined output).
    static func run(_ args: [String], repoPath: String, uvOverride: String) async -> (Int32, String) {
        guard let (exe, base) = command("ei", repoPath: repoPath, uvOverride: uvOverride) else {
            return (-1, "Can't find the ei CLI. Run `uv sync` in \(repoPath).")
        }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = base + args
            p.currentDirectoryURL = URL(fileURLWithPath: repoPath)
            p.environment = environment()
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (proc.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)) }
        }
    }
}
