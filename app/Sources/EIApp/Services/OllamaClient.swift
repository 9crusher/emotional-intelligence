import AppKit
import Foundation
import Observation

/// Talks to the local Ollama server (loopback only, like the daemon) to list, pull, and
/// delete models. Which model the daemon uses is the `ollama_model` setting.
@Observable @MainActor
final class OllamaClient {
    struct InstalledModel: Identifiable, Equatable {
        let name: String
        let size: Int64
        let family: String?
        let parameterSize: String?
        var id: String { name }
    }

    struct PullProgress: Equatable {
        var status: String
        var completed: Int64 = 0
        var total: Int64 = 0
        var fraction: Double? { total > 0 ? Double(completed) / Double(total) : nil }
    }

    var reachable: Bool?
    var installed: [InstalledModel] = []
    var loaded: Set<String> = []
    var pulls: [String: PullProgress] = [:]
    var lastError: String?

    @ObservationIgnored private var pullTasks: [String: Task<Void, Never>] = [:]
    private let base = URL(string: "http://127.0.0.1:11434")!

    func refresh() async {
        do {
            let tags: TagsResponse = try await get("api/tags")
            installed = tags.models.map {
                InstalledModel(name: $0.name, size: $0.size, family: $0.details?.family,
                               parameterSize: $0.details?.parameter_size)
            }.sorted { $0.name < $1.name }
            let ps: TagsResponse = try await get("api/ps")
            loaded = Set(ps.models.map(\.name))
            reachable = true
        } catch {
            reachable = false
        }
    }

    func isInstalled(_ name: String) -> Bool {
        installed.contains { $0.name == name || $0.name == "\(name):latest" }
    }

    func startOllama() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["ollama", "serve"]
            p.environment = EICLI.environment()
            try? p.run()
        }
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                await refresh()
                if reachable == true { return }
            }
        }
    }

    func pull(_ name: String) {
        guard pullTasks[name] == nil else { return }
        pulls[name] = PullProgress(status: "Starting…")
        pullTasks[name] = Task {
            defer {
                pullTasks[name] = nil
                pulls[name] = nil
            }
            do {
                var req = URLRequest(url: base.appending(path: "api/pull"))
                req.httpMethod = "POST"
                req.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                for try await line in bytes.lines {
                    guard let msg = try? JSONDecoder().decode(PullMessage.self, from: Data(line.utf8)) else { continue }
                    if let error = msg.error { throw OllamaError(message: error) }
                    var p = pulls[name] ?? PullProgress(status: msg.status ?? "")
                    p.status = msg.status ?? p.status
                    if let total = msg.total { p.total = total }
                    if let completed = msg.completed { p.completed = completed }
                    pulls[name] = p
                }
                await refresh()
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                lastError = "Couldn't download \(name): \(error.localizedDescription)"
            }
        }
    }

    func cancelPull(_ name: String) {
        pullTasks[name]?.cancel()
    }

    func delete(_ name: String) async {
        do {
            var req = URLRequest(url: base.appending(path: "api/delete"))
            req.httpMethod = "DELETE"
            req.httpBody = try JSONSerialization.data(withJSONObject: ["model": name])
            _ = try await URLSession.shared.data(for: req)
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: base.appending(path: path))
        req.timeoutInterval = 3
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            struct Details: Decodable {
                let family: String?
                let parameter_size: String?
            }
            let name: String
            let size: Int64
            let details: Details?
        }
        let models: [Model]
    }

    private struct PullMessage: Decodable {
        let status: String?
        let total: Int64?
        let completed: Int64?
        let error: String?
    }

    struct OllamaError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
