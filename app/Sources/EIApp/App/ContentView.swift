import SwiftUI

enum ViewType: String, CaseIterable, Identifiable {
    case dashboard, models, triggers, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Overview"
        case .models: "AI Models"
        case .triggers: "Triggers"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.medium"
        case .models: "cpu"
        case .triggers: "bolt.fill"
        case .settings: "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .dashboard: .orange
        case .models: .green
        case .triggers: .indigo
        case .settings: .gray
        }
    }

    static let main: [ViewType] = [.dashboard, .models, .triggers]
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar()
                .frame(width: AppTheme.Layout.sidebarWidth)
            Divider()
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(0.5)
                detail
            }
        }
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .dashboard: DashboardView()
        case .models: ModelCatalogView()
        case .triggers: TriggersView()
        case .settings: SettingsView()
        }
    }
}

struct AppSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                SidebarIconTile(systemName: "eye", color: AppTheme.warm, size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Emotional").font(.system(size: 13, weight: .bold))
                    Text("Intelligence").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 48)  // clear the traffic lights
            .padding(.bottom, 18)

            ForEach(ViewType.main) { row($0) }
            Spacer(minLength: 0)
            row(.settings)
            statusFooter
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    private func row(_ view: ViewType) -> some View {
        let selected = model.selection == view
        return Button { model.selection = view } label: {
            HStack(spacing: 9) {
                SidebarIconTile(systemName: view.icon, color: view.color)
                Text(view.title).font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.row, style: .continuous)
                    .fill(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusFooter: some View {
        let status = model.statusLine
        return HStack(spacing: 7) {
            Circle().fill(status.color).frame(width: 8, height: 8)
                .shadow(color: status.color.opacity(0.6), radius: 3)
            Text(status.text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.row, style: .continuous).fill(AppTheme.Surface.subtle)
        )
        .padding(.top, 8)
    }
}
