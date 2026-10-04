import AppKit
import SwiftUI

/// Curated local vision models known to work with Ollama structured output.
/// Sizes are approximate download sizes; scores are relative, for comparison only.
struct CatalogModel: Identifiable {
    let name: String
    let displayName: String
    let approxSize: String
    let speed: Double
    let accuracy: Double
    let description: String
    var recommended = false
    var id: String { name }

    static let all: [CatalogModel] = [
        .init(name: "qwen2.5vl:3b", displayName: "Qwen2.5-VL 3B", approxSize: "~3.2 GB", speed: 8.5, accuracy: 6.5,
              description: "Small and quick. A good fit for short capture intervals or machines with less memory."),
        .init(name: "qwen2.5vl:7b", displayName: "Qwen2.5-VL 7B", approxSize: "~6.0 GB", speed: 6.5, accuracy: 8.5,
              description: "The default. Reliable structured output and a careful eye for posture, gaze and hands.",
              recommended: true),
        .init(name: "gemma3:4b", displayName: "Gemma 3 4B", approxSize: "~3.3 GB", speed: 8.0, accuracy: 6.5,
              description: "Google's compact multimodal model. Fast, good general scene understanding."),
        .init(name: "gemma3:12b", displayName: "Gemma 3 12B", approxSize: "~8.1 GB", speed: 4.5, accuracy: 8.5,
              description: "Larger Gemma. More detail, slower; best with 32 GB of memory or more."),
        .init(name: "minicpm-v:8b", displayName: "MiniCPM-V 8B", approxSize: "~5.5 GB", speed: 6.0, accuracy: 7.5,
              description: "Strong at fine visual detail like expressions and hand positions."),
        .init(name: "llava:7b", displayName: "LLaVA 7B", approxSize: "~4.7 GB", speed: 6.5, accuracy: 5.5,
              description: "The classic open vision model. Widely available, less precise than newer models."),
    ]
}

struct ModelCatalogView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        let ollama = model.ollama
        VStack(alignment: .leading, spacing: AppTheme.Layout.section) {
            AppScreenHeader(title: "AI Models",
                            subtitle: "Local vision models that describe what the camera sees. Everything runs on this Mac via Ollama.") {
                AppIconButton(systemName: "arrow.clockwise", help: "Refresh") { Task { await ollama.refresh() } }
                AppIconButton(systemName: "gearshape", help: "Model settings") { showSettings = true }
            }

            ollamaBanner

            if let error = ollama.lastError {
                WarningCard(icon: "exclamationmark.triangle.fill", title: "Something went wrong", message: error,
                            actionTitle: "Dismiss") { ollama.lastError = nil }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Vision models")
                ForEach(CatalogModel.all) { ModelCard(catalog: $0, name: $0.name) }
            }

            let others = ollama.installed.filter { m in
                !CatalogModel.all.contains { $0.name == m.name || "\($0.name):latest" == m.name }
            }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Other installed models",
                                 trailing: "Only vision-capable models will work")
                    ForEach(others) { ModelCard(catalog: nil, name: $0.name) }
                }
            }
        }
        .appPage()
        .task {
            await ollama.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await ollama.refresh()
            }
        }
        .sidePanel(isPresented: $showSettings) { ModelSettingsPanel { showSettings = false } }
    }

    @ViewBuilder private var ollamaBanner: some View {
        let ollama = model.ollama
        HStack(spacing: 12) {
            SidebarIconTile(systemName: "server.rack", color: ollama.reachable == true ? .green : .gray, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(ollama.reachable == true ? "Ollama is running" : ollama.reachable == false ? "Ollama isn't running" : "Checking Ollama…")
                    .font(.system(size: 13, weight: .semibold))
                Text(ollama.reachable == true
                     ? "\(ollama.installed.count) model\(ollama.installed.count == 1 ? "" : "s") installed · using \(model.store.settings.ollamaModel)"
                     : "Start Ollama to download models and analyze captures.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if ollama.reachable == false {
                Button("Start Ollama") { ollama.startOllama() }.buttonStyle(.appPrimary)
                Button("Get Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                    .buttonStyle(.appSecondary)
            }
        }
        .appCard()
    }
}

private struct ModelCard: View {
    @Environment(AppModel.self) private var model
    let catalog: CatalogModel?
    let name: String

    var body: some View {
        let ollama = model.ollama
        let installed = ollama.installed.first { $0.name == name || $0.name == "\(name):latest" }
        let isDefault = model.store.settings.ollamaModel == name
            || "\(model.store.settings.ollamaModel):latest" == name
        let pull = ollama.pulls[name]

        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(catalog?.displayName ?? name).font(.system(size: 13, weight: .semibold))
                    if catalog?.recommended == true {
                        Text("Recommended").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                    if ollama.loaded.contains(installed?.name ?? name) {
                        Text("Loaded").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    }
                }
                HStack(spacing: 14) {
                    Label(name, systemImage: "shippingbox").font(.system(size: 11, design: .monospaced))
                    Label(installed.map { formatBytes($0.size) } ?? catalog?.approxSize ?? "—", systemImage: "internaldrive")
                        .font(.system(size: 11))
                    if let catalog {
                        ProgressDots(label: "Speed", score: catalog.speed)
                        ProgressDots(label: "Accuracy", score: catalog.accuracy)
                    }
                }
                .foregroundStyle(.secondary)
                if let catalog {
                    Text(catalog.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                if let pull {
                    VStack(alignment: .leading, spacing: 3) {
                        if let f = pull.fraction {
                            ProgressView(value: f).progressViewStyle(.linear)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Text(pull.total > 0
                             ? "\(pull.status.capitalized) · \(formatBytes(pull.completed)) of \(formatBytes(pull.total))"
                             : pull.status.capitalized)
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if pull != nil {
                    Button("Cancel") { ollama.cancelPull(name) }
                        .buttonStyle(CapsuleButtonStyle(tint: .red))
                } else if installed != nil {
                    if isDefault {
                        Label("Default", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Button("Use") { model.store.set("ollama_model", name) }
                            .buttonStyle(CapsuleButtonStyle())
                    }
                    Menu {
                        Button("Set as Default") { model.store.set("ollama_model", name) }.disabled(isDefault)
                        Divider()
                        Button("Delete Model", role: .destructive) { Task { await ollama.delete(installed!.name) } }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 15))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Button {
                        ollama.pull(name)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(ollama.reachable != true)
                }
            }
        }
        .padding(16)
        .background(AppCardBackground(isSelected: isDefault))
    }
}

private struct ModelSettingsPanel: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var keepAlive = ""
    @State private var testing = false
    @State private var testOutput: String?

    var body: some View {
        let s = model.store.settings
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Model Settings", close: close)
            Form {
                Section {
                    LabeledContent("Active model") { Text(s.ollamaModel).font(.system(.body, design: .monospaced)) }
                    TextField("Keep loaded for", text: $keepAlive)
                        .onSubmit { model.store.set("ollama_keep_alive", keepAlive) }
                    Picker("Image size", selection: Binding(
                        get: { s.imageMaxSide }, set: { model.store.set("image_max_side", $0) })) {
                        ForEach([256, 384, 512, 768, 1024], id: \.self) { Text("\($0) px").tag($0) }
                    }
                } footer: {
                    Text("“Keep loaded for” is how long Ollama keeps the model in memory between captures (e.g. 10m, 1h). Keep it longer than the capture interval to avoid slow cold starts. Larger images give the model more detail but are slower.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("Test") {
                    Button {
                        runTest()
                    } label: {
                        HStack {
                            Text(testing ? "Capturing…" : "Capture one frame and analyze it")
                            if testing { Spacer(); ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(testing)
                    if let testOutput {
                        Text(testOutput).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { keepAlive = s.ollamaKeepAlive }
    }

    private func runTest() {
        testing = true
        testOutput = nil
        Task {
            let (_, out) = await EICLI.run(["capture-once"], repoPath: model.daemon.repoPath,
                                           uvOverride: model.daemon.uvPathOverride)
            testOutput = out.trimmingCharacters(in: .whitespacesAndNewlines)
            testing = false
        }
    }
}
