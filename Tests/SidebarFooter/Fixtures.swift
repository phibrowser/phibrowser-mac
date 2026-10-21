// Copyright 2026 Phinomenon Inc.
// Local stand-ins for services and unrelated controls. Production footer and Chat views are compiled unchanged.
import AppKit
import SwiftUI
import Combine

class ApplicationState { static let shared = ApplicationState(); let isGuest = false }
class DownloadButtonViewModel: ObservableObject { let downloadsManager: Int? = nil }
class NotificationCardManager: ObservableObject { @Published var latestCard: Int? = 1 }
enum WebContentConstant { static let edgesSpacing: CGFloat = 8 }
struct ProfileButton: View {
    enum Surface { case sidebar }; let surface: Surface
    var body: some View { Button {} label: { Image(systemName: "person.crop.circle.fill").resizable().frame(width: 24, height: 24) }.buttonStyle(.plain) }
}
struct DownloadButtonView: View {
    let viewModel: DownloadButtonViewModel; let onTap: () -> Void
    var body: some View { Button(action: onTap) { Image(systemName: "arrow.down").frame(width: 24, height: 24) }.buttonStyle(.plain) }
}
struct MemoryButton: View {
    let action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: "brain").frame(width: 24, height: 24) }.buttonStyle(.plain) }
}
struct SidebarDownloadsPopoverPresenter: View {
    @Binding var isPresented: Bool; let downloadsManager: Int?
    var body: some View { EmptyView() }
}
enum FixtureImage { case sidebarFeedback, cardBulbIcon, sidebarChat
    var name: String { switch self { case .sidebarFeedback: "ladybug"; case .cardBulbIcon: "lightbulb.fill"; case .sidebarChat: "bubble.left.fill" } }
}
extension NSImage { convenience init(resource: FixtureImage) { self.init(systemSymbolName: resource.name, accessibilityDescription: nil)! } }
extension Image { init(_ resource: FixtureImage) { self.init(systemName: resource.name) } }
enum ThemedColor { case themeColor, themeColorOnHover, textPrimary }
struct Appearance { var isDark = false }
struct AppearanceKey: EnvironmentKey { static let defaultValue = Appearance() }
extension EnvironmentValues { var phiAppearance: Appearance { get { self[AppearanceKey.self] } set { self[AppearanceKey.self] = newValue } } }
extension View {
    func themedBackground(_ color: ThemedColor) -> some View { background(Color.blue) }
    func themedForeground(_ color: ThemedColor) -> some View { foregroundStyle(Color.primary) }
}
extension NSColor { static var sidebarTabHovered: NSColor { .controlBackgroundColor } }
extension Color { static var sidebarTabHovered: Color { Color(nsColor: .sidebarTabHovered) } }

@MainActor enum Probe { static var frames: [String: CGRect] = [:] }
struct FrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
extension View {
    func probe(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: FrameKey.self, value: [name: geometry.frame(in: .global)])
        }).onPreferenceChange(FrameKey.self) { frames in
            MainActor.assumeIsolated { Probe.frames.merge(frames, uniquingKeysWith: { _, new in new }) }
        }
    }
}
