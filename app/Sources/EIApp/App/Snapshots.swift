import AppKit
import SwiftUI

/// Development aid: with `EI_SNAPSHOT_DIR` set, renders the window and each full page to
/// `<dir>/` as PNGs and quits. Lets layouts be checked without screen recording permission.
@MainActor
enum Snapshots {
    nonisolated static let isActive = ProcessInfo.processInfo.environment["EI_SNAPSHOT_DIR"] != nil

    static func runIfRequested(_ model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["EI_SNAPSHOT_DIR"] else { return }
        let out = URL(fileURLWithPath: dir)
        Task {
            try? await Task.sleep(for: .seconds(4))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                let suffix = appearance == .aqua ? "light" : "dark"
                for view in ViewType.allCases {
                    model.selection = view
                    try? await Task.sleep(for: .seconds(1))
                    if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                       let content = window.contentView?.superview {
                        write(content, to: out.appending(path: "window-\(view.rawValue)-\(suffix).png"))
                    }
                    // Full page at its natural height.
                    let host = NSHostingView(rootView: page(view).environment(model).frame(width: 740)
                        .background(Color(nsColor: .windowBackgroundColor)))
                    host.appearance = NSAppearance(named: appearance)
                    host.frame.size = host.fittingSize
                    host.layoutSubtreeIfNeeded()
                    write(host, to: out.appending(path: "\(view.rawValue)-\(suffix).png"))
                }
            }
            let editor = NSHostingView(rootView: TriggerEditorPanel(original: TriggerPreset.all[1].rule) {}
                .environment(model).frame(width: 440, height: 1000)
                .background(Color(nsColor: .windowBackgroundColor)))
            editor.appearance = NSAppearance(named: .aqua)
            editor.frame.size = editor.fittingSize
            editor.layoutSubtreeIfNeeded()
            write(editor, to: out.appending(path: "trigger-editor.png"))

            for agent in AgentSetupPanel.Agent.allCases {
                let panel = NSHostingView(rootView: AgentSetupPanel(agent: agent) {}
                    .environment(model).frame(width: 460, height: 820)
                    .background(Color(nsColor: .windowBackgroundColor)))
                panel.appearance = NSAppearance(named: .aqua)
                panel.frame.size = panel.fittingSize
                panel.layoutSubtreeIfNeeded()
                write(panel, to: out.appending(path: "agent-setup-\(agent == .codex ? "codex" : "claude").png"))
            }

            // EI_SELFTEST: exercise the write path (only ever point this at a scratch EI_DB).
            if ProcessInfo.processInfo.environment["EI_SELFTEST"] != nil {
                try? model.store.save(TriggerPreset.all[3].rule)
                model.store.set("interval_s", 5.0)
                model.store.set("ollama_keep_alive", "15m")
                model.store.captureNow()
                try? await Task.sleep(for: .seconds(8))
            }
            NSApp.terminate(nil)
        }
    }

    @ViewBuilder private static func page(_ view: ViewType) -> some View {
        switch view {
        case .dashboard: DashboardView()
        case .models: ModelCatalogView()
        case .triggers: TriggersView()
        case .settings: SettingsView().frame(height: 1700)
        }
    }

    private static func write(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
