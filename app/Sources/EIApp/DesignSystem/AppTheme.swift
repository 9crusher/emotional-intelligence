import AppKit
import SwiftUI

/// Visual tokens. The look follows VoiceInk: translucent sidebar material, quiet cards on
/// `controlBackgroundColor`, system accent, continuous corners, system font.
enum AppTheme {
    enum Radius {
        static let card: CGFloat = 12
        static let heroCard: CGFloat = 16
        static let pill: CGFloat = 22
        static let row: CGFloat = 10
        static let tile: CGFloat = 6
        static let button: CGFloat = 9
    }

    enum Layout {
        static let pageH: CGFloat = 24
        static let pageV: CGFloat = 28
        static let section: CGFloat = 22
        static let cardPadding: CGFloat = 16
        static let sidebarWidth: CGFloat = 220
    }

    enum Surface {
        static let card = Color(nsColor: .controlBackgroundColor).opacity(0.5)
        static let border = Color(nsColor: .separatorColor).opacity(0.35)
        static let subtle = Color.primary.opacity(0.05)
    }

    static let warm = Color(red: 0.86, green: 0.42, blue: 0.20)  // hero accent (burnt orange)
}

// MARK: - Window material

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}

// MARK: - Cards

struct AppCardBackground: View {
    var radius: CGFloat = AppTheme.Radius.card
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(AppTheme.Surface.card)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(isSelected ? Color.primary.opacity(0.14) : AppTheme.Surface.border,
                            lineWidth: isSelected ? 1.5 : 1)
            )
    }
}

extension View {
    func appCard(radius: CGFloat = AppTheme.Radius.card, padding: CGFloat = AppTheme.Layout.cardPadding) -> some View {
        self.padding(padding).background(AppCardBackground(radius: radius))
    }

    /// Standard page container: scrolls, pads like VoiceInk's screens.
    @ViewBuilder func appPage() -> some View {
        let page = self
            .padding(.horizontal, AppTheme.Layout.pageH)
            .padding(.vertical, AppTheme.Layout.pageV)
            .frame(maxWidth: .infinity, alignment: .leading)
        if Snapshots.isActive {
            page  // cacheDisplay can't capture ScrollView content; snapshots render pages unscrolled
        } else {
            ScrollView { page }.scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Headers

struct AppScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 28, weight: .bold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension AppScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct SectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Buttons

struct AppActionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.button, style: .continuous)
                    .fill(background.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.button, style: .continuous)
                    .stroke(kind == .secondary ? AppTheme.Surface.border : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: .primary
        case .destructive: .white
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .accentColor
        case .secondary: Color(nsColor: .controlBackgroundColor)
        case .destructive: .red
        }
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(filled ? .white : tint)
            .background(Capsule().fill(filled ? tint : tint.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == AppActionButtonStyle {
    static var appPrimary: AppActionButtonStyle { .init(kind: .primary) }
    static var appSecondary: AppActionButtonStyle { .init(kind: .secondary) }
    static var appDestructive: AppActionButtonStyle { .init(kind: .destructive) }
}

struct AppIconButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.button, style: .continuous)
                        .fill(hovering ? AppTheme.Surface.subtle : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
