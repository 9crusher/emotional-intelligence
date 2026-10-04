import AppKit
import SwiftUI

/// Step-by-step instructions for registering ei-mcp (and, for Claude Code, ei-hook) with an agent.
/// Paths point at the repo's .venv, so the snippets work without uv on the agent's PATH.
struct AgentSetupPanel: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    enum Agent: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case codex = "Codex"
        var id: String { rawValue }
    }

    @State private var agent: Agent
    @State private var status = ConfigStatus()

    init(agent: Agent = .claudeCode, close: @escaping () -> Void) {
        _agent = State(initialValue: agent)
        self.close = close
    }

    static let serverName = "emotional-intelligence"

    private var mcpExe: String { venvBin("ei-mcp") }
    private var hookExe: String { venvBin("ei-hook") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Connect an Agent", close: close)
            Picker("", selection: $agent) {
                ForEach(Agent.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !FileManager.default.isExecutableFile(atPath: mcpExe) {
                        Label("\(mcpExe) doesn't exist yet. Run `uv sync` in the project folder first.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                    }
                    switch agent {
                    case .claudeCode: claudeCodeSteps
                    case .codex: codexSteps
                    }
                }
                .padding(20)
            }
        }
        .onAppear { status = ConfigStatus.read() }
        .onChange(of: agent) { status = ConfigStatus.read() }
    }

    // MARK: Claude Code

    @ViewBuilder private var claudeCodeSteps: some View {
        StepView(number: 1, title: "Add the MCP server",
                 detail: "Run this in a terminal. `--scope user` makes it available in every project.",
                 status: status.claudeMCP) {
            CodeBlock(text: "claude mcp add --scope user \(Self.serverName) -- \(shellQuote(mcpExe))")
        }
        StepView(number: nil, title: "Or edit the config by hand",
                 detail: "Add this to `.mcp.json` in a project (just that project) or to `mcpServers` in `~/.claude.json` (all projects).") {
            CodeBlock(text: """
            {
              "mcpServers": {
                "\(Self.serverName)": { "command": "\(mcpExe)" }
              }
            }
            """)
        }
        StepView(number: 2, title: "Optional: deliver trigger nudges",
                 detail: "Registers ei-hook so triggers set to “Tell the agent” reach Claude Code. Merge into `~/.claude/settings.json`.",
                 status: status.claudeHook) {
            CodeBlock(text: hookJSON)
        }
        StepView(number: 3, title: "Restart Claude Code",
                 detail: "Start a new session, then run `/mcp` to check that \(Self.serverName) is connected.") {
            EmptyView()
        }
    }

    // MARK: Codex

    @ViewBuilder private var codexSteps: some View {
        StepView(number: 1, title: "Add the MCP server",
                 detail: "Run this in a terminal.",
                 status: status.codexMCP) {
            CodeBlock(text: "codex mcp add \(Self.serverName) -- \(shellQuote(mcpExe))")
        }
        StepView(number: nil, title: "Or edit the config by hand",
                 detail: "Add this to `~/.codex/config.toml`.") {
            CodeBlock(text: """
            [mcp_servers.\(Self.serverName)]
            command = "\(mcpExe)"
            """)
        }
        StepView(number: 2, title: "Restart Codex",
                 detail: "Start a new session, then run `/mcp` to check that \(Self.serverName) is listed. Trigger nudges are delivered through Claude Code hooks only.") {
            EmptyView()
        }
    }

    // MARK: Helpers

    private func venvBin(_ name: String) -> String {
        (model.daemon.repoPath as NSString).appendingPathComponent(".venv/bin/\(name)")
    }

    /// Mirrors `ei hook-config`.
    private var hookJSON: String {
        let hook = #"{ "type": "command", "command": "\#(hookExe)", "timeout": 5 }"#
        return """
        {
          "hooks": {
            "PostToolUse": [{ "matcher": "*", "hooks": [\(hook)] }],
            "UserPromptSubmit": [{ "hooks": [\(hook)] }]
          }
        }
        """
    }

    private func shellQuote(_ s: String) -> String {
        s.contains(where: { " '\"$\\".contains($0) }) ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s
    }
}

/// Whether each agent's config already mentions us. Best effort: only the user-level files are checked.
private struct ConfigStatus {
    var claudeMCP: Bool?
    var claudeHook: Bool?
    var codexMCP: Bool?

    static func read() -> ConfigStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func text(_ path: String) -> String? { try? String(contentsOf: home.appending(path: path), encoding: .utf8) }

        var s = ConfigStatus()
        if let data = text(".claude.json")?.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let servers = json["mcpServers"] as? [String: Any] ?? [:]
            s.claudeMCP = servers[AgentSetupPanel.serverName] != nil
        }
        if let settings = text(".claude/settings.json") { s.claudeHook = settings.contains("ei-hook") }
        if let toml = text(".codex/config.toml") {
            s.codexMCP = toml.contains("[mcp_servers.\(AgentSetupPanel.serverName)]")
                || toml.contains("[mcp_servers.\"\(AgentSetupPanel.serverName)\"]")
        }
        return s
    }
}

private struct StepView<Content: View>: View {
    let number: Int?
    let title: String
    let detail: String
    var status: Bool? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let number {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(AppTheme.warm))
                }
                Text(title).font(.system(size: 13, weight: number == nil ? .medium : .semibold))
                    .foregroundStyle(number == nil ? .secondary : .primary)
                Spacer(minLength: 0)
                if status == true {
                    StatusPill(text: "Configured", color: .green)
                }
            }
            Text(.init(detail))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }
}

private struct CodeBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? .green : .secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.leading, 10)
        .padding([.vertical, .trailing], 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.06)))
    }
}
