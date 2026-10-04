import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: AppTheme.Layout.section) {
            header
            if !store.dbAvailable {
                WarningCard(icon: "externaldrive.badge.questionmark", title: "No database yet",
                            message: "Start the daemon to create \(Store.dbPath.path).")
            }
            if case .failed(let message) = model.daemon.status {
                WarningCard(icon: "exclamationmark.triangle.fill", title: "The daemon isn't running",
                            message: message, actionTitle: "Start") {
                    model.daemon.start(knownState: store.daemonState)
                }
            }
            if let error = store.daemonState?.lastError, store.daemonState?.lastStatus == "error" {
                WarningCard(icon: "exclamationmark.triangle.fill", title: "Last capture failed",
                            message: error, actionTitle: "AI Models") { model.selection = .models }
            }
            SummaryStats()
            Feed()
        }
        .appPage()
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            AppScreenHeader(title: "Overview", subtitle: status(now: context.date)) {
                Button(model.store.settings.paused ? "Resume" : "Pause") {
                    model.store.set("paused", !model.store.settings.paused)
                }
                .buttonStyle(.appSecondary)
            }
        }
    }

    private func status(now: Date) -> String {
        if model.store.settings.paused { return "Paused" }
        if !model.daemon.isRunning { return "Not capturing" }
        guard let tick = model.store.daemonState?.lastTick else { return "Starting…" }
        return "Capturing · last checked \(relative(tick, now: now))"
    }
}

// MARK: - Summary

private struct SummaryStats: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let presentS = store.today.share("present", "true") * store.today.observedS
        HStack(spacing: 0) {
            stat(store.current.map(summary) ?? "—", "Right now")
            Divider().padding(.vertical, 4)
            stat(formatDuration(presentS), "At the desk today")
            Divider().padding(.vertical, 4)
            stat("\(store.capturesToday)", "Captures today")
        }
        .fixedSize(horizontal: false, vertical: true)
        .appCard()
    }

    private func summary(_ c: Capture) -> String {
        c.isAway ? "Away" : c.facts["activity"]?.first.map(FactStyle.pretty) ?? "Present"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

// MARK: - Feed

private struct Feed: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Recent")
            if model.store.recent.isEmpty {
                Text("Nothing yet. Captures show up here as the daemon analyzes frames.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(spacing: 0) {
                        ForEach(Array(model.store.recent.prefix(25).enumerated()), id: \.element.id) { i, c in
                            if i > 0 { Divider() }
                            row(c, now: context.date)
                        }
                    }
                }
            }
        }
    }

    private func row(_ c: Capture, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(relative(c.ts, now: now))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(describe(c)).font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .textSelection(.enabled)
    }

    private func describe(_ c: Capture) -> String {
        if c.isAway { return "Away" }
        let parts = orderedKeys(c.facts.keys).filter { $0 != "present" }
            .compactMap { k in c.facts[k]?.first.map { FactStyle.pretty($0, key: k) } }
        return parts.isEmpty ? "Present" : parts.joined(separator: " · ")
    }
}

// MARK: - Shared

struct WarningCard: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.appSecondary)
            }
        }
        .appCard()
    }
}

func relative(_ date: Date, now: Date) -> String {
    let s = now.timeIntervalSince(date)
    if s < 10 { return "just now" }
    if s < 60 { return "\(Int(s))s ago" }
    if s < 3600 { return "\(Int(s / 60))m ago" }
    if s < 86400 { return "\(Int(s / 3600))h ago" }
    return date.formatted(date: .abbreviated, time: .shortened)
}
