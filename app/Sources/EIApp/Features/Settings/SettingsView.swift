import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var repoPath = ""
    @State private var uvPath = ""
    @State private var loginError: String?
    @State private var copied: String?
    @State private var showAgentSetup = false

    var body: some View {
        let store = model.store
        let s = store.settings
        VStack(alignment: .leading, spacing: 0) {
            AppScreenHeader(title: "Settings")
                .padding(.horizontal, AppTheme.Layout.pageH)
                .padding(.top, AppTheme.Layout.pageV)
            Form {
                Section("Capture") {
                    Toggle("Pause capture", isOn: bind(s.paused, "paused"))
                    LabeledContent {
                        HStack {
                            Slider(value: Binding(get: { s.intervalS }, set: { store.set("interval_s", $0.rounded()) }),
                                   in: 5...300)
                                .frame(width: 200)
                            Text(formatDuration(s.intervalS)).monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    } label: {
                        labelWithTip("Check every", "How often the camera is sampled. Unchanged frames are skipped cheaply, so short intervals mostly cost a quick face check.")
                    }
                    Picker("Camera", selection: Binding(get: { s.cameraIndex }, set: { store.set("camera_index", $0) })) {
                        ForEach(0..<4, id: \.self) { Text($0 == 0 ? "Default camera (0)" : "Camera \($0)").tag($0) }
                    }
                    Toggle(isOn: bind(s.keepCameraOpen, "keep_camera_open")) {
                        labelWithTip("Keep camera open", "Faster captures, but the camera light stays on. Off: the camera opens briefly for each capture.")
                    }
                    Toggle(isOn: bind(s.requireFace, "require_face")) {
                        labelWithTip("Only analyze when a face is visible", "Skips the vision model when no face is detected, and records you as away.")
                    }
                }

                Section("Change detection") {
                    LabeledContent {
                        HStack {
                            Slider(value: Binding(get: { s.changeThreshold }, set: { store.set("change_threshold", ($0 * 2).rounded() / 2) }),
                                   in: 0...20)
                                .frame(width: 200)
                            Text(String(format: "%.1f", s.changeThreshold)).monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    } label: {
                        labelWithTip("Change threshold", "How different a frame must be from the last analyzed one to be analyzed again. Lower = more sensitive, more model calls.")
                    }
                    Picker(selection: Binding(get: { s.maxSkipS }, set: { store.set("max_skip_s", $0) })) {
                        ForEach([60.0, 120, 300, 600, 900, 1800], id: \.self) { Text(formatDuration($0)).tag($0) }
                    } label: {
                        labelWithTip("Re-check at least every", "Analyze anyway after this long, even if nothing seems to have changed.")
                    }
                }

                Section("Data") {
                    Picker("Keep history for", selection: Binding(get: { s.retentionDays }, set: { store.set("retention_days", $0) })) {
                        ForEach([1, 7, 14, 30, 90, 365], id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                    }
                    Picker(selection: Binding(get: { s.agentEventTtlS }, set: { store.set("agent_event_ttl_s", $0) })) {
                        ForEach([60.0, 300, 900, 3600], id: \.self) { Text(formatDuration($0)).tag($0) }
                    } label: {
                        labelWithTip("Agent nudges expire after", "Agent-bound trigger events older than this are dropped instead of delivered, so a new session doesn't replay stale nudges.")
                    }
                    LabeledContent("Database") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.dbPath]) }
                    }
                }

                Section("Daemon") {
                    LabeledContent("Status") {
                        StatusPill(text: model.statusLine.text, color: model.statusLine.color)
                    }
                    Toggle("Start capturing when the app opens",
                           isOn: Binding(get: { model.startOnLaunch }, set: { model.startOnLaunch = $0 }))
                    LabeledContent("Control") {
                        HStack {
                            if model.daemon.isRunning {
                                Button("Restart") { model.daemon.restart(knownState: nil) }
                                Button("Stop") { model.daemon.stop() }
                            } else {
                                Button("Start") { model.daemon.start(knownState: store.daemonState) }
                            }
                        }
                    }
                    TextField("Project folder", text: $repoPath)
                        .onSubmit { model.daemon.repoPath = repoPath }
                    TextField("uv path (optional)", text: $uvPath, prompt: Text("auto-detect"))
                        .onSubmit { model.daemon.uvPathOverride = uvPath }
                }

                Section("Integrations") {
                    LabeledContent {
                        Button(copied == "hook" ? "Copied!" : "Copy JSON") { copyHookConfig() }
                    } label: {
                        labelWithTip("Claude Code hook", "Settings snippet that registers ei-hook, so agent triggers reach Claude Code. Paste into ~/.claude/settings.json.")
                    }
                    LabeledContent {
                        Button("Set Up…") { showAgentSetup = true }
                    } label: {
                        labelWithTip("Connect Claude Code or Codex", "Step-by-step instructions for adding the ei-mcp server to your agent, so it can read your recent behavior.")
                    }
                }

                Section("General") {
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { on in
                            do { try model.setLaunchAtLogin(on); loginError = nil } catch { loginError = error.localizedDescription }
                        }))
                    if let loginError {
                        Text(loginError).font(.system(size: 11)).foregroundStyle(.red)
                    }
                    Toggle("Hide Dock icon (menu bar only)",
                           isOn: Binding(get: { model.hideDockIcon }, set: { model.hideDockIcon = $0 }))
                }

                Section("Diagnostics") {
                    Toggle(isOn: Binding(get: { model.daemon.fakeMode }, set: {
                        model.daemon.fakeMode = $0
                        if model.daemon.isRunning { model.daemon.restart(knownState: nil) }
                    })) {
                        labelWithTip("Fake mode", "Run the daemon with a fake camera and analyzer — no camera or Ollama needed. Useful for trying out the app.")
                    }
                    DaemonLogView(lines: model.daemon.log)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .sidePanel(isPresented: $showAgentSetup, width: 460) {
            AgentSetupPanel { showAgentSetup = false }
        }
        .onAppear {
            repoPath = model.daemon.repoPath
            uvPath = model.daemon.uvPathOverride
        }
    }

    private func bind(_ value: Bool, _ key: String) -> Binding<Bool> {
        Binding(get: { value }, set: { model.store.set(key, $0) })
    }

    private func labelWithTip(_ title: String, _ tip: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            InfoTip(text: tip)
        }
    }

    private func copyHookConfig() {
        Task {
            let (code, out) = await EICLI.run(["hook-config"], repoPath: model.daemon.repoPath,
                                              uvOverride: model.daemon.uvPathOverride)
            if code == 0 { copy(out, tag: "hook") }
        }
    }

    private func copy(_ text: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        copied = tag
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == tag { copied = nil }
        }
    }
}

private struct DaemonLogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(line.contains("ERROR") || line.contains("Traceback") ? .red : .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(8)
            }
            .frame(height: 180)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.06)))
            .onChange(of: lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            .overlay {
                if lines.isEmpty {
                    Text("No daemon output yet").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
