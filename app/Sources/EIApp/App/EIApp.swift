import AppKit
import ServiceManagement
import SwiftUI

/// Shared app state: the DB-backed store, the daemon process, and the Ollama client.
@Observable @MainActor
final class AppModel {
    static let shared = AppModel()

    let store = Store()
    let daemon = DaemonController()
    let ollama = OllamaClient()
    var selection: ViewType = .dashboard

    var startOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: "startOnLaunch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "startOnLaunch") }
    }

    var hideDockIcon: Bool {
        get { UserDefaults.standard.bool(forKey: "hideDockIcon") }
        set {
            UserDefaults.standard.set(newValue, forKey: "hideDockIcon")
            NSApp.setActivationPolicy(newValue ? .accessory : .regular)
        }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    func bootstrap() {
        store.start()
        Task {
            // `ei vocab` also makes sure the DB exists and is migrated before the first read.
            let (code, out) = await EICLI.run(["vocab"], repoPath: daemon.repoPath, uvOverride: daemon.uvPathOverride)
            if code == 0, let data = out.split(separator: "\n").last.map({ Data($0.utf8) }),
               let vocab = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
            {
                store.vocab = vocab
            }
            _ = await EICLI.run(["settings"], repoPath: daemon.repoPath, uvOverride: daemon.uvPathOverride)
            store.refresh(force: true)
            if startOnLaunch { daemon.start(knownState: store.daemonState) }
        }
        Task { await ollama.refresh() }
    }

    /// Short description for the sidebar footer and menu bar.
    var statusLine: (text: String, color: Color) {
        switch daemon.status {
        case .failed: return ("Daemon error", .red)
        case .stopped: return ("Daemon stopped", .gray)
        case .starting: return ("Starting…", .yellow)
        case .running, .external:
            if store.settings.paused { return ("Paused", .orange) }
            return ("Capturing · every \(formatDuration(store.settings.intervalS))", .green)
        }
    }
}

@main
struct EIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Emotional Intelligence", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 950, minHeight: 700)
                .onAppear {
                    if !model.hideDockIcon { NSApp.setActivationPolicy(.regular) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 760)

        MenuBarExtra {
            MenuBarMenu().environment(model)
        } label: {
            Image(systemName: model.store.settings.paused || !model.daemon.isRunning ? "eye.slash" : "eye")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quit cleanly (stopping the daemon) on SIGTERM/SIGINT too, not just via the menu.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        MainActor.assumeIsolated {
            if AppModel.shared.hideDockIcon { NSApp.setActivationPolicy(.accessory) }
            AppModel.shared.bootstrap()
            Snapshots.runIfRequested(AppModel.shared)
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            // Closing the last real window drops the Dock icon; capture continues from the menu bar.
            guard let closing = note.object as? NSWindow, closing.styleMask.contains(.titled) else { return }
            let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
            if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.daemon.stopAndWait() }
    }
}

struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.statusLine
        Text(status.text)
        if let c = model.store.current {
            Text(c.isAway ? "Away" : c.factsText.replacingOccurrences(of: "_", with: " "))
        }
        Divider()
        Button(model.store.settings.paused ? "Resume Capture" : "Pause Capture") {
            model.store.set("paused", !model.store.settings.paused)
        }
        Button("Capture Now") { model.store.captureNow() }
            .disabled(!model.daemon.isRunning)
        Divider()
        Button("Open Dashboard…") { open(.dashboard) }
        Button("Triggers…") { open(.triggers) }
        Button("Settings…") { open(.settings) }
        Divider()
        if model.daemon.isRunning {
            Button("Restart Daemon") { model.daemon.restart(knownState: nil) }
            Button("Stop Daemon") { model.daemon.stop() }
        } else {
            Button("Start Daemon") { model.daemon.start(knownState: model.store.daemonState) }
        }
        Divider()
        Button("Quit Emotional Intelligence") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ view: ViewType) {
        model.selection = view
        if !model.hideDockIcon { NSApp.setActivationPolicy(.regular) }
        openWindow(id: "main")
        NSApp.activate()
    }
}
