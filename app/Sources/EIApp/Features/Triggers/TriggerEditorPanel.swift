import SwiftUI

/// Side panel for creating/editing a trigger. Conditions: every chosen key must match (AND);
/// within a key, any selected value matches (OR) — same semantics as `ei.triggers.Trigger`.
struct TriggerEditorPanel: View {
    @Environment(AppModel.self) private var model
    let original: TriggerRule
    let close: () -> Void
    @State private var draft: TriggerRule
    @State private var saveError: String?

    init(original: TriggerRule, close: @escaping () -> Void) {
        self.original = original
        self.close = close
        _draft = State(initialValue: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: original.id == nil ? "New Trigger" : "Edit Trigger", close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    field("Name") {
                        TextField("e.g. Slouching", text: $draft.name).textFieldStyle(.roundedBorder)
                    }
                    conditions
                    field("When") {
                        Picker("", selection: $draft.kind) {
                            Text("As soon as it starts").tag(TriggerRule.Kind.onEnter)
                            Text("After it lasts…").tag(TriggerRule.Kind.sustained)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        if draft.kind == .sustained {
                            DurationField(label: "Lasts at least", seconds: $draft.forS)
                        }
                        DurationField(label: "Cooldown", seconds: $draft.cooldownS)
                        Text("After firing, wait at least this long before firing again.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    field("Then") {
                        Picker("", selection: $draft.action) {
                            ForEach(TriggerRule.Action.allCases) { a in
                                Label(a.label, systemImage: a.icon).tag(a)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Text(draft.action == .agent
                             ? "Delivered to Claude Code through the ei-hook on your next prompt or tool call."
                             : "Shown as a macOS notification right away.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("Message", text: $draft.message, axis: .vertical)
                            .lineLimit(3...6)
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Enabled", isOn: $draft.enabled)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            Divider()
            if let problem = saveError ?? validationProblem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(saveError == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            HStack {
                if original.id != nil {
                    Button("Delete", role: .destructive) {
                        model.store.delete(original)
                        close()
                    }
                    .buttonStyle(.appDestructive)
                }
                Spacer()
                Button("Cancel", action: close).buttonStyle(.appSecondary)
                Button("Save") {
                    do {
                        try model.store.save(cleaned)
                        close()
                    } catch {
                        saveError = "Couldn't save: \(error.localizedDescription)"
                    }
                }
                .buttonStyle(.appPrimary)
                .disabled(validationProblem != nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .onChange(of: draft) { saveError = nil }
    }

    private var conditions: some View {
        field("If I'm…") {
            let vocab = model.store.vocab
            let keys = orderedKeys(Set(vocab.keys).union(draft.conditions.keys))
            if keys.isEmpty {
                Text("Vocabulary unavailable — run `uv sync` in the project, then reopen this panel.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(keys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 6) {
                    Label(FactStyle.label(for: key), systemImage: FactStyle.icon(for: key))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(draft.conditions[key]?.isEmpty == false ? .primary : .secondary)
                    FlowLayout(spacing: 5) {
                        let values = vocab[key] ?? []
                        let extra = (draft.conditions[key] ?? []).filter { !values.contains($0) }
                        ForEach(values + extra, id: \.self) { value in
                            ValueToggle(label: key == "present" ? FactStyle.pretty(value, key: key) : FactStyle.pretty(value),
                                        isOn: selected(key, value))
                        }
                    }
                }
            }
            Text("All checked groups must match. Within a group, any checked value matches.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func selected(_ key: String, _ value: String) -> Binding<Bool> {
        Binding(
            get: { draft.conditions[key]?.contains(value) ?? false },
            set: { on in
                var values = draft.conditions[key] ?? []
                if on { if !values.contains(value) { values.append(value) } } else { values.removeAll { $0 == value } }
                draft.conditions[key] = values.isEmpty ? nil : values
            })
    }

    private var cleaned: TriggerRule {
        var t = draft
        t.name = t.name.trimmingCharacters(in: .whitespaces)
        t.message = t.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.kind == .onEnter { t.forS = 0 }
        return t
    }

    /// Why Save is disabled, shown above the buttons; nil when the trigger can be saved.
    private var validationProblem: String? {
        let t = cleaned
        if t.name.isEmpty { return "Give the trigger a name." }
        if t.conditions.isEmpty { return "Pick at least one condition." }
        if t.kind == .sustained && t.forS <= 0 { return "Set how long it has to last." }
        if t.message.isEmpty { return "Write a message." }
        return nil
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }
}

private struct ValueToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 4) {
                if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                Text(label)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(isOn ? Color.white : .primary)
            .background(Capsule().fill(isOn ? Color.accentColor : AppTheme.Surface.subtle))
            .overlay(Capsule().stroke(isOn ? .clear : AppTheme.Surface.border, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Number + unit (seconds / minutes / hours), stored as seconds.
struct DurationField: View {
    let label: String
    @Binding var seconds: Double
    @State private var unit: Double = 60
    @State private var text = ""

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12.5))
            Spacer()
            TextField("0", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
            Picker("", selection: $unit) {
                Text("sec").tag(1.0)
                Text("min").tag(60.0)
                Text("hours").tag(3600.0)
            }
            .labelsHidden()
            .frame(width: 84)
        }
        .onAppear {
            unit = seconds > 0 && seconds.truncatingRemainder(dividingBy: 3600) == 0 ? 3600
                : seconds > 0 && seconds.truncatingRemainder(dividingBy: 60) != 0 ? 1 : 60
            text = seconds > 0 ? (seconds / unit).formatted(.number.precision(.fractionLength(0...1)).grouping(.never)) : ""
        }
        .onChange(of: text) { commit() }
        .onChange(of: unit) { commit() }
    }

    /// Updates the bound value on every keystroke; a value-formatted TextField only commits
    /// on Return or focus loss, so clicking Save right after typing dropped the number.
    private func commit() {
        let n = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
        seconds = max(0, n * unit)
    }
}
