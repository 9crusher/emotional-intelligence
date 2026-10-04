import Foundation

/// key -> values; the VLM reports one value per key. Mirrors `ei.db.Facts`.
typealias Facts = [String: [String]]

/// Keys in display order (mirrors `ei.queries.KEY_ORDER`).
let factKeyOrder = ["present", "activity", "gaze", "expression", "posture", "hands"]

func orderedKeys(_ keys: some Sequence<String>) -> [String] {
    let keys = Set(keys)
    return factKeyOrder.filter(keys.contains) + keys.subtracting(factKeyOrder).sorted()
}

struct Capture: Identifiable, Equatable {
    let id: Int64
    let ts: Date
    let analyzer: String
    let model: String?
    let latencyMs: Int?
    let facts: Facts
    let notes: String?
    let gate: String?

    var isAway: Bool { facts["present"] == ["false"] }

    /// One-line rendering, e.g. "activity=working gaze=screen" (mirrors `format_facts`).
    var factsText: String {
        if isAway { return "away" }
        return orderedKeys(facts.keys)
            .filter { $0 != "present" }
            .map { "\($0)=\(facts[$0]!.joined(separator: ","))" }
            .joined(separator: " ")
    }
}

struct TriggerRule: Identifiable, Equatable {
    var id: Int64?
    var name: String = ""
    var enabled: Bool = true
    var conditions: [String: [String]] = [:]
    var kind: Kind = .onEnter
    var forS: Double = 0
    var cooldownS: Double = 0
    var action: Action = .osNotify
    var message: String = ""

    enum Kind: String, CaseIterable, Identifiable {
        case onEnter = "on_enter"
        case sustained
        var id: String { rawValue }
        var label: String { self == .onEnter ? "On enter" : "Sustained" }
    }

    enum Action: String, CaseIterable, Identifiable {
        case agent
        case osNotify = "os_notify"
        var id: String { rawValue }
        var label: String { self == .agent ? "Tell the agent" : "Notification" }
        var icon: String { self == .agent ? "sparkles" : "bell.fill" }
    }
}

struct FiredEvent: Identifiable, Equatable {
    let id: Int64
    let ts: Date
    let triggerName: String?
    let action: String
    let message: String
    let delivered: Bool
}

struct DaemonState: Equatable {
    let pid: Int32
    let startedAt: Date
    let lastTick: Date?
    let lastStatus: String?
    let lastError: String?
}

/// The stretch of time one observation's facts hold for (until the next one, capped at `max_gap_s`).
struct FactSpan: Equatable {
    let start: Date
    let end: Date
    /// False for the carried-over observation from before the window.
    let captured: Bool
    let facts: Facts

    func has(_ tag: FactTag) -> Bool { facts[tag.key]?.contains(tag.value) ?? false }
}

/// A single key=value, e.g. hands=face.
struct FactTag: Hashable, Identifiable {
    let key: String
    let value: String

    var id: String { "\(key)=\(value)" }
    var label: String { FactStyle.pretty(value, key: key) }

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    init?(_ id: String) {
        let parts = id.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        self.init(key: parts[0], value: parts[1])
    }
}

/// Time-weighted share of observed time per key/value (mirrors `ei.queries.BehaviorSummary`).
struct BehaviorSummary: Equatable {
    struct Share: Equatable {
        let value: String
        let share: Double
    }

    var observedS: Double = 0
    /// key -> shares, most common first
    var shares: [String: [Share]] = [:]

    func share(_ key: String, _ value: String) -> Double {
        shares[key]?.first { $0.value == value }?.share ?? 0
    }

    func top(_ key: String) -> String? { shares[key]?.first?.value }
}

/// Typed mirror of `ei.settings.Settings`. Python is the source of truth for defaults;
/// these must match it.
struct EISettings: Equatable {
    var paused = false
    var intervalS = 30.0
    var cameraIndex = 0
    var keepCameraOpen = false
    var ollamaModel = "qwen2.5vl:7b"
    var ollamaKeepAlive = "10m"
    var imageMaxSide = 512
    var requireFace = true
    var changeThreshold = 4.0
    var maxSkipS = 300.0
    var retentionDays = 30
    var agentEventTtlS = 300.0

    var maxGapS: Double { maxSkipS + 2 * intervalS + 60 }

    init() {}

    init(overrides: [String: Any]) {
        func num(_ k: String) -> NSNumber? { overrides[k] as? NSNumber }
        if let v = num("paused") { paused = v.boolValue }
        if let v = num("interval_s") { intervalS = v.doubleValue }
        if let v = num("camera_index") { cameraIndex = v.intValue }
        if let v = num("keep_camera_open") { keepCameraOpen = v.boolValue }
        if let v = overrides["ollama_model"] as? String { ollamaModel = v }
        if let v = overrides["ollama_keep_alive"] as? String { ollamaKeepAlive = v }
        if let v = num("image_max_side") { imageMaxSide = v.intValue }
        if let v = num("require_face") { requireFace = v.boolValue }
        if let v = num("change_threshold") { changeThreshold = v.doubleValue }
        if let v = num("max_skip_s") { maxSkipS = v.doubleValue }
        if let v = num("retention_days") { retentionDays = v.intValue }
        if let v = num("agent_event_ttl_s") { agentEventTtlS = v.doubleValue }
    }
}

// MARK: - Display helpers

enum FactStyle {
    static func icon(for key: String) -> String {
        switch key {
        case "present": "person.fill.checkmark"
        case "activity": "laptopcomputer"
        case "gaze": "eye"
        case "expression": "face.smiling"
        case "posture": "figure.seated.side.right"
        case "hands": "hand.raised"
        default: "circle.dashed"
        }
    }

    static func label(for key: String) -> String {
        key.prefix(1).uppercased() + key.dropFirst().replacingOccurrences(of: "_", with: " ")
    }

    static func pretty(_ value: String) -> String {
        let s = value.replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Value phrased so it reads unambiguously on its own (gaze "away" vs activity "away").
    static func pretty(_ value: String, key: String) -> String {
        switch (key, value) {
        case ("gaze", _): "Looking " + (value == "screen" ? "at screen" : pretty(value).lowercased())
        case ("activity", "eating_drinking"): "Eating or drinking"
        case ("hands", "desk"): "Hands on desk"
        case ("hands", "face"): "Hand on face"
        case ("hands", "not_visible"): "Hands not visible"
        case ("present", "true"): "Present"
        case ("present", "false"): "Away"
        default: pretty(value)
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s >= 3600 {
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
    if s >= 60 {
        let m = s / 60, r = s % 60
        return r == 0 ? "\(m)m" : "\(m)m \(r)s"
    }
    return "\(s)s"
}
