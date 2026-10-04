import SwiftUI

/// Colored rounded tile with a white SF Symbol and a soft glossy top, as in VoiceInk's sidebar.
struct SidebarIconTile: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous)
            .fill(color.gradient)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center))
            )
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }
}

/// A single observed fact, e.g. [eye] Screen.
struct FactChip: View {
    let key: String
    let value: String
    var large = false
    var showKey = false
    var text: String?

    var body: some View {
        HStack(spacing: large ? 6 : 4) {
            Image(systemName: FactStyle.icon(for: key))
                .font(.system(size: large ? 12 : 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if showKey {
                Text(FactStyle.label(for: key) + ":").foregroundStyle(.secondary)
            }
            Text(text ?? FactStyle.pretty(value, key: key))
        }
        .font(.system(size: large ? 13 : 11.5, weight: .medium))
        .padding(.horizontal, large ? 10 : 7)
        .padding(.vertical, large ? 6 : 3)
        .background(Capsule().fill(AppTheme.Surface.subtle))
        .overlay(Capsule().stroke(AppTheme.Surface.border, lineWidth: 0.5))
        .help(FactStyle.label(for: key))
    }
}

/// All facts of a capture as chips, in display order.
struct FactChips: View {
    let facts: Facts
    var large = false

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(orderedKeys(facts.keys).filter { $0 != "present" }, id: \.self) { key in
                ForEach(facts[key] ?? [], id: \.self) { value in
                    FactChip(key: key, value: value, large: large)
                }
            }
        }
    }
}

/// Five dots + score, colored by score (VoiceInk's speed/accuracy indicator).
struct ProgressDots: View {
    let label: String
    let score: Double  // 0...10

    var body: some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(Double(i) < (score / 2).rounded() ? color : Color.primary.opacity(0.12))
                        .frame(width: 6, height: 6)
                }
            }
            Text(String(format: "%.1f", score))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch score {
        case 8...: .green
        case 6..<8: .yellow
        case 4..<6: .orange
        default: .red
        }
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    var dot = true

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(color).frame(width: 7, height: 7) }
            Text(text)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
        .foregroundStyle(dot ? Color.primary : color)
    }
}

struct InfoTip: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .trailing) {
            Text(text).font(.system(size: 12)).padding(12).frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - Side panel (slides in from the right, as VoiceInk's settings panels do)

struct SidePanelModifier<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    var width: CGFloat = 400
    @ViewBuilder var panel: () -> Panel

    func body(content: Content) -> some View {
        content.overlay {
            ZStack(alignment: .trailing) {
                if isPresented {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { isPresented = false }
                        .transition(.opacity)
                    panel()
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(
                            VisualEffectView(material: .popover, blendingMode: .withinWindow)
                                .ignoresSafeArea()
                        )
                        .overlay(alignment: .leading) { Divider() }
                        .shadow(color: .black.opacity(0.12), radius: 16, x: -4)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.25), value: isPresented)
        }
    }
}

extension View {
    func sidePanel<Panel: View>(isPresented: Binding<Bool>, width: CGFloat = 400,
                                @ViewBuilder panel: @escaping () -> Panel) -> some View {
        modifier(SidePanelModifier(isPresented: isPresented, width: width, panel: panel))
    }
}

struct PanelHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 17, weight: .semibold))
            Spacer()
            AppIconButton(systemName: "xmark", help: "Close", action: close)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .init(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !row.indices.isEmpty && row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
