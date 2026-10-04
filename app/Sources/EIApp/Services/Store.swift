import Foundation
import Observation

/// Read side and settings/trigger writes over the shared SQLite database.
/// Query logic mirrors `src/ei/queries.py`; keep the two in step.
@Observable @MainActor
final class Store {
    var recent: [Capture] = []
    var settings = EISettings()
    var triggers: [TriggerRule] = []
    var events: [FiredEvent] = []
    var daemonState: DaemonState?
    var today = BehaviorSummary()
    var capturesToday = 0
    var vocab: [String: [String]] = [:]
    var dbAvailable = false
    var lastError: String?

    var current: Capture? { recent.first }

    @ObservationIgnored private var db: Database?
    @ObservationIgnored private var dataVersion: Int64 = -1
    @ObservationIgnored private var lastFullRefresh = Date.distantPast
    @ObservationIgnored private var timer: Timer?

    static var dbPath: URL {
        if let env = ProcessInfo.processInfo.environment["EI_DB"] {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/emotional-intelligence/ei.db")
    }

    func start() {
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Reloads when another connection committed (daemon wrote, CLI changed something), and
    /// at least every 30s so time windows stay current.
    func refresh(force: Bool = false) {
        if db == nil {
            db = try? Database(path: Self.dbPath.path)
        }
        guard let db else {
            dbAvailable = false
            return
        }
        dbAvailable = true
        let version = (try? db.query("PRAGMA data_version").first?.int("data_version")) ?? -1
        let stale = Date().timeIntervalSince(lastFullRefresh) > 30
        guard force || stale || version != dataVersion else { return }
        dataVersion = version
        lastFullRefresh = Date()

        do {
            settings = try loadSettings(db)
            recent = try loadRecent(db, limit: 25)
            let now = Date()
            today = try timeShares(db, from: Calendar.current.startOfDay(for: now), to: now)
            capturesToday = try countToday(db, now: now)
            triggers = try loadTriggers(db)
            events = try loadEvents(db, limit: 20)
            daemonState = try? loadDaemonState(db)  // table appears with migration 4
            if vocab.isEmpty { vocab = try observedVocab(db) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Writes

    /// Writes one `settings` row as JSON, exactly as `ei.settings.set_value` does.
    func set(_ key: String, _ value: Any) {
        guard let db else { return }
        do {
            try db.execute(
                """
                INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
                [.text(jsonLiteral(value)), .int(nowMs())].withKey(key)
            )
            refresh(force: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func captureNow() {
        set("capture_requested_at", Int(nowMs()))
    }

    /// Inserts or updates a trigger. Throws so the editor can stay open and show what went wrong.
    func save(_ t: TriggerRule) throws {
        guard let db else { throw DatabaseError(message: "The database isn't available. Start the daemon first.") }
        let conditions = (try? JSONSerialization.data(withJSONObject: t.conditions, options: .sortedKeys))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let forS = t.kind == .sustained ? t.forS : 0
        var params: [SQLValue] = [
            .text(t.name), .int(t.enabled ? 1 : 0), .text(conditions), .text(t.kind.rawValue),
            .double(forS), .double(t.cooldownS), .text(t.action.rawValue), .text(t.message),
            .int(nowMs()),
        ]
        if let id = t.id {
            params.append(.int(id))
            try db.execute(
                """
                UPDATE triggers SET name = ?, enabled = ?, conditions = ?, kind = ?, for_s = ?,
                    cooldown_s = ?, action = ?, message = ?, updated_at = ? WHERE id = ?
                """, params)
        } else {
            try db.execute(
                """
                INSERT INTO triggers (name, enabled, conditions, kind, for_s, cooldown_s, action,
                    message, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, params)
        }
        refresh(force: true)
    }

    func setEnabled(_ t: TriggerRule, _ enabled: Bool) {
        guard let db, let id = t.id else { return }
        _ = try? db.execute(
            "UPDATE triggers SET enabled = ?, updated_at = ? WHERE id = ?",
            [.int(enabled ? 1 : 0), .int(nowMs()), .int(id)])
        refresh(force: true)
    }

    func delete(_ t: TriggerRule) {
        guard let db, let id = t.id else { return }
        _ = try? db.execute("DELETE FROM triggers WHERE id = ?", [.int(id)])
        refresh(force: true)
    }

    // MARK: Reads

    private func loadSettings(_ db: Database) throws -> EISettings {
        var overrides: [String: Any] = [:]
        for row in try db.query("SELECT key, value FROM settings") {
            guard let key = row.string("key"), let raw = row.string("value"),
                  let value = try? JSONSerialization.jsonObject(
                      with: Data(raw.utf8), options: .fragmentsAllowed)
            else { continue }
            overrides[key] = value
        }
        return EISettings(overrides: overrides)
    }

    private func loadRecent(_ db: Database, limit: Int) throws -> [Capture] {
        let rows = try db.query(
            """
            SELECT id, ts, analyzer, model, latency_ms, payload FROM observations
            ORDER BY ts DESC LIMIT ?
            """, [.int(Int64(limit))])
        let facts = try factsFor(db, rows.compactMap { $0.int("id") })
        return rows.compactMap { r in
            guard let id = r.int("id"), let ts = r.int("ts") else { return nil }
            let payload = decodePayload(r.string("payload"))
            return Capture(
                id: id, ts: date(ms: ts), analyzer: r.string("analyzer") ?? "",
                model: r.string("model"), latencyMs: r.int("latency_ms").map(Int.init),
                facts: facts[id] ?? [:],
                notes: (payload["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                gate: payload["gate"] as? String)
        }
    }

    /// Port of `queries._time_shares`: each observation holds until the next one, capped at
    /// `max_gap_s`, and the last observation before the window carries into it.
    private func timeShares(_ db: Database, from: Date, to: Date) throws -> BehaviorSummary {
        let start = ms(from), end = ms(to)
        let rows = try db.query(
            """
            SELECT id, ts FROM observations WHERE ts >= ? AND ts < ?
            UNION ALL
            SELECT * FROM (SELECT id, ts FROM observations WHERE ts < ? ORDER BY ts DESC LIMIT 1)
            ORDER BY ts
            """, [.int(start), .int(end), .int(start)])
        let facts = try factsFor(db, rows.compactMap { $0.int("id") })
        let maxGapMs = Int64(settings.maxGapS * 1000)

        var weight: [String: [String: Int64]] = [:]
        var observed: Int64 = 0
        for (i, r) in rows.enumerated() {
            guard let id = r.int("id"), let ts = r.int("ts") else { continue }
            let nextTs = i + 1 < rows.count ? (rows[i + 1].int("ts") ?? end) : end
            let held = min(nextTs, ts + maxGapMs, end) - max(ts, start)
            guard held > 0 else { continue }
            observed += held
            for (key, values) in facts[id] ?? [:] {
                for v in values { weight[key, default: [:]][v, default: 0] += held }
            }
        }
        var summary = BehaviorSummary(observedS: Double(observed) / 1000)
        guard observed > 0 else { return summary }
        for (key, values) in weight {
            summary.shares[key] = values
                .map { .init(value: $0.key, share: Double($0.value) / Double(observed)) }
                .sorted { $0.share > $1.share }
        }
        return summary
    }

    private func countToday(_ db: Database, now: Date) throws -> Int {
        let start = ms(Calendar.current.startOfDay(for: now))
        let row = try db.query(
            """
            SELECT COUNT(*) AS n FROM observations o WHERE ts >= ? AND NOT EXISTS (
                SELECT 1 FROM facts f WHERE f.observation_id = o.id
                AND f.key = 'present' AND f.value = 'false')
            """, [.int(start)]).first
        return Int(row?.int("n") ?? 0)
    }

    private func loadTriggers(_ db: Database) throws -> [TriggerRule] {
        try db.query("SELECT * FROM triggers ORDER BY id").map { r in
            let conditions = r.string("conditions")
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: [String]] }
            return TriggerRule(
                id: r.int("id"), name: r.string("name") ?? "", enabled: r.int("enabled") == 1,
                conditions: conditions ?? [:],
                kind: TriggerRule.Kind(rawValue: r.string("kind") ?? "") ?? .onEnter,
                forS: r.double("for_s") ?? 0, cooldownS: r.double("cooldown_s") ?? 0,
                action: TriggerRule.Action(rawValue: r.string("action") ?? "") ?? .agent,
                message: r.string("message") ?? "")
        }
    }

    private func loadEvents(_ db: Database, limit: Int) throws -> [FiredEvent] {
        try db.query(
            """
            SELECT e.*, t.name AS trigger_name FROM events e
            LEFT JOIN triggers t ON t.id = e.trigger_id ORDER BY e.ts DESC LIMIT ?
            """, [.int(Int64(limit))]
        ).compactMap { r in
            guard let id = r.int("id"), let ts = r.int("ts") else { return nil }
            return FiredEvent(
                id: id, ts: date(ms: ts), triggerName: r.string("trigger_name"),
                action: r.string("action") ?? "", message: r.string("message") ?? "",
                delivered: r.int("delivered_at") != nil)
        }
    }

    private func loadDaemonState(_ db: Database) throws -> DaemonState? {
        guard let r = try db.query("SELECT * FROM daemon_state WHERE id = 1").first,
              let pid = r.int("pid"), let started = r.int("started_at")
        else { return nil }
        return DaemonState(
            pid: Int32(pid), startedAt: date(ms: started), lastTick: r.int("last_tick_ts").map(date(ms:)),
            lastStatus: r.string("last_status"), lastError: r.string("last_error"))
    }

    /// Fallback vocabulary from values already recorded, used until `ei vocab` answers.
    private func observedVocab(_ db: Database) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for r in try db.query("SELECT DISTINCT key, value FROM facts ORDER BY key, value") {
            if let k = r.string("key"), let v = r.string("value") { out[k, default: []].append(v) }
        }
        return out
    }

    private func factsFor(_ db: Database, _ ids: [Int64]) throws -> [Int64: Facts] {
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var out: [Int64: Facts] = [:]
        for r in try db.query(
            "SELECT observation_id, key, value FROM facts WHERE observation_id IN (\(marks))",
            ids.map { .int($0) })
        {
            guard let id = r.int("observation_id"), let k = r.string("key"), let v = r.string("value")
            else { continue }
            out[id, default: [:]][k, default: []].append(v)
        }
        return out
    }
}

// MARK: - Helpers

func nowMs() -> Int64 { ms(Date()) }
func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

private func decodePayload(_ raw: String?) -> [String: Any] {
    guard let raw, let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) else { return [:] }
    return obj as? [String: Any] ?? [:]
}

/// JSON encoding of a single settings value, matching Python's `json.dumps` for the same type.
private func jsonLiteral(_ value: Any) -> String {
    switch value {
    case let b as Bool: return b ? "true" : "false"
    case let i as Int: return String(i)
    case let d as Double: return d.isFinite ? String(d) : "0.0"
    case let s as String:
        let data = (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "\"\""
    default: return "null"
    }
}

private extension Array where Element == SQLValue {
    func withKey(_ key: String) -> [SQLValue] { [.text(key)] + self }
}
