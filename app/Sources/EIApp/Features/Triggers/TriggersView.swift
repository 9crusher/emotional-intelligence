import SwiftUI

struct TriggersView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: TriggerRule?

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: AppTheme.Layout.section) {
            AppScreenHeader(title: "Triggers",
                            subtitle: "React when you've been in a state for a while: nudge your agent or show a notification.") {
                Button {
                    editing = TriggerRule()
                } label: {
                    Label("New Trigger", systemImage: "plus")
                }
                .buttonStyle(.appPrimary)
            }

            if store.triggers.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    EmptyStateView(icon: "bolt.badge.clock", title: "No triggers yet",
                                   message: "Start from an example or create your own.")
                    SectionTitle(title: "Examples")
                    ForEach(TriggerPreset.all) { preset in
                        PresetRow(preset: preset) { editing = preset.rule }
                    }
                }
                .appCard(radius: AppTheme.Radius.heroCard)
            } else {
                VStack(spacing: 10) {
                    ForEach(store.triggers) { t in
                        TriggerCard(trigger: t) { editing = t }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Recently fired")
                if store.events.isEmpty {
                    Text("Nothing has fired yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        VStack(spacing: 0) {
                            ForEach(Array(store.events.enumerated()), id: \.element.id) { i, e in
                                if i > 0 { Divider() }
                                EventRow(event: e, now: context.date)
                            }
                        }
                    }
                }
            }
        }
        .appPage()
        .sidePanel(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), width: 440) {
            if let editing {
                TriggerEditorPanel(original: editing) { self.editing = nil }
                    .id(editing.id ?? -1)
            }
        }
    }
}

private struct TriggerCard: View {
    @Environment(AppModel.self) private var model
    let trigger: TriggerRule
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SidebarIconTile(systemName: trigger.action.icon, color: trigger.enabled ? .indigo : .gray, size: 30)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(trigger.name).font(.system(size: 13.5, weight: .semibold))
                    Text(timing).font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.Surface.subtle))
                        .foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 6) {
                    ForEach(orderedKeys(trigger.conditions.keys), id: \.self) { key in
                        FactChip(key: key, value: "", showKey: true,
                                 text: (trigger.conditions[key] ?? []).map(FactStyle.pretty).joined(separator: " or "))
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: trigger.action.icon)
                    Text(trigger.action.label + ":")
                    Text(trigger.message).lineLimit(1)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Toggle("", isOn: Binding(get: { trigger.enabled }, set: { model.store.setEnabled(trigger, $0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                AppIconButton(systemName: "pencil", help: "Edit trigger", action: edit)
                    .opacity(hovering ? 1 : 0.5)
            }
        }
        .padding(16)
        .background(AppCardBackground())
        .opacity(trigger.enabled ? 1 : 0.65)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: edit)
    }

    private var timing: String {
        var parts = [trigger.kind == .sustained ? "for \(formatDuration(trigger.forS))" : "on enter"]
        if trigger.cooldownS > 0 { parts.append("cooldown \(formatDuration(trigger.cooldownS))") }
        return parts.joined(separator: " · ")
    }
}

private struct EventRow: View {
    let event: FiredEvent
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.action == "agent" ? "sparkles" : "bell.fill")
                .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.triggerName ?? "(deleted trigger)").font(.system(size: 12.5, weight: .semibold))
                Text(event.message).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            StatusPill(text: event.delivered ? "Delivered" : "Pending", color: event.delivered ? .green : .orange)
            Text(relative(event.ts, now: now)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Presets

struct TriggerPreset: Identifiable {
    let rule: TriggerRule
    let icon: String
    var id: String { rule.name }

    static let all: [TriggerPreset] = [
        .init(rule: TriggerRule(name: "Slouching", conditions: ["posture": ["slouched"]], kind: .sustained,
                                forS: 600, cooldownS: 1800, action: .osNotify,
                                message: "You've been slouching for 10 minutes. Sit up and roll your shoulders."),
              icon: "figure.seated.side.right"),
        .init(rule: TriggerRule(name: "Frustration signs", conditions: ["expression": ["frowning"]],
                                kind: .sustained, forS: 300, cooldownS: 1800, action: .agent,
                                message: "The user has looked tense for ~5 minutes. Check in briefly and offer to simplify."),
              icon: "sparkles"),
        .init(rule: TriggerRule(name: "Looking tired", conditions: ["expression": ["yawning"]], kind: .onEnter,
                                cooldownS: 3600, action: .osNotify,
                                message: "Yawning — time for a 20-20-20 break?"),
              icon: "eye"),
        .init(rule: TriggerRule(name: "Back at the desk", conditions: ["present": ["true"]], kind: .onEnter,
                                cooldownS: 600, action: .agent,
                                message: "The user just returned to the desk."),
              icon: "person.fill.checkmark"),
    ]
}

private struct PresetRow: View {
    let preset: TriggerPreset
    let use: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SidebarIconTile(systemName: preset.icon, color: .indigo, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.rule.name).font(.system(size: 13, weight: .semibold))
                Text(preset.rule.message).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Use", action: use).buttonStyle(CapsuleButtonStyle(filled: false))
        }
    }
}
