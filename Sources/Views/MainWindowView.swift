import SwiftUI
import AppKit

enum MainPage: CaseIterable, Equatable {
    case home
    case history
    case dictionary
    case settings

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        case .settings: "gearshape"
        }
    }
}

struct MainWindowView: View {
    @Environment(AppState.self) private var app

    /// Room for the traffic lights, since the content runs under the transparent title bar.
    static let titleBarInset: CGFloat = 40

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 200)

            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 0) {
                if app.mainPage != .home {
                    Text(app.mainPage.title)
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.horizontal, Theme.s5)
                        .padding(.bottom, Theme.s2)
                }
                page
            }
            .padding(.top, Self.titleBarInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    @ViewBuilder private var page: some View {
        switch app.mainPage {
        case .home: HomeView()
        case .history: HistoryView()
        case .dictionary: DictionaryView()
        case .settings: SettingsView()
        }
    }
}

private struct Sidebar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.s2) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text("Yap Flow")
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, Theme.s2)
            .padding(.bottom, Theme.s4)

            ForEach([MainPage.home, .history, .dictionary], id: \.self) { page in
                SidebarItem(page: page)
            }

            Spacer(minLength: Theme.s4)

            DictationStatus()
                .padding(.horizontal, Theme.s2)
                .padding(.bottom, Theme.s3)

            SidebarItem(page: .settings)
        }
        .padding(.horizontal, Theme.s3)
        .padding(.top, MainWindowView.titleBarInset + Theme.s1)
        .padding(.bottom, Theme.s3)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SidebarMaterial())
    }
}

private struct SidebarItem: View {
    @Environment(AppState.self) private var app
    let page: MainPage
    @State private var hovering = false

    private var selected: Bool { app.mainPage == page }

    var body: some View {
        Button {
            app.mainPage = page
        } label: {
            HStack(spacing: Theme.s2 + 2) {
                Image(systemName: page.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, Theme.s2)
            .padding(.vertical, 7)
            .background(
                selected ? Theme.hairlineStrong : (hovering ? Theme.surfaceHover : .clear),
                in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Shows whether Yap is listening right now, and how to start when it isn't.
private struct DictationStatus: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: Theme.s2) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var dotColor: Color {
        switch app.coordinator.state {
        case .recording: Theme.recording
        case .transcribing, .inserting: Color.orange
        case .idle: Theme.success
        }
    }

    private var label: String {
        switch app.coordinator.state {
        case .recording: "Listening…"
        case .transcribing, .inserting: "Writing…"
        case .idle: app.pushToTalkFn ? "Ready · hold fn" : "Ready"
        }
    }
}

/// The translucent sidebar background macOS apps use.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct PageHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: Theme.s2) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Back").font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            // Balances the back button so the title stays optically centred.
            Color.clear.frame(width: 52, height: 1)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
    }
}
