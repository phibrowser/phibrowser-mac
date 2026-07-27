import AppKit
import SnapKit
import SwiftUI

/// Tab-scoped native renderer crash page. Created for a specific crashed tab
/// and never reads `focusingTab` — a background or split-pane tab can host its
/// own crash view independently. The overall layout mirrors Chrome's sad tab;
/// the controls use the Mac client's native styles (bordered-prominent button,
/// link-styled help). All copy comes from `CrashPageData` (Chromium-sourced).
final class RendererCrashViewController: NSViewController {
    private let tabId: Int
    private let data: CrashPageData
    private weak var host: MainBrowserWindowController?
    private var hostingController: ThemedHostingController<RendererCrashView>?

    init(tabId: Int, data: CrashPageData, host: MainBrowserWindowController) {
        self.tabId = tabId
        self.data = data
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installCrashView()
    }

    private func installCrashView() {
        let crashView = RendererCrashView(
            data: data,
            onPrimaryAction: { [weak self] in self?.performPrimaryAction() },
            onHelp: { [weak self] in self?.openHelpLink() }
        )
        let hosting = ThemedHostingController(rootView: crashView,
                                              themeSource: host?.browserState.themeContext)
        // Do NOT let the SwiftUI content's ideal size propagate as the hosting
        // controller's preferredContentSize — that climbs the VC chain and
        // resizes the window. The overlay must only fill its container.
        // (sizingOptions is macOS 13+; macOS 12 hosting controllers don't
        // propagate preferredContentSize automatically.)
        if #available(macOS 13.0, *) {
        hosting.sizingOptions = []
        }
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        hostingController = hosting
    }

    /// Chrome's sad tab uses a single action button whose role flips with
    /// `showFeedbackButton`: reload normally, send-feedback when repeatedly
    /// crashing. The label (`buttonLabel`) already matches the chosen role.
    private func performPrimaryAction() {
        switch data.primaryAction {
        case .reload:
            host?.browserState.resolveTab(tabId)?.reload()
        case .feedback:
            guard let host else { return }
            // Pass THIS crashed tab so feedback prefills its url/title regardless
            // of focus (a split partner pane's crash isn't the focused tab).
            host.showFeedbackWindow(crashContextTab: host.browserState.resolveTab(tabId))
        }
    }

    private func openHelpLink() {
        host?.browserState.openTab(data.helpLinkUrl)
    }
}

/// SwiftUI body of the crash page. Layout mirrors Chrome's sad tab (a centered,
/// leading-aligned column); colors use AppKit semantic colors so the page
/// adapts to light/dark via the injected theme appearance.
private struct RendererCrashView: View {
    let data: CrashPageData
    let onPrimaryAction: () -> Void
    let onHelp: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.secondary)

                Text(data.title)
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text(data.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !data.tips.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(data.tips, id: \.self) { tip in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                Text(tip)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.callout)
                }

                if !data.errorCodeText.isEmpty {
                    Text(data.errorCodeText)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 16) {
                    Button(data.buttonLabel, action: onPrimaryAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)

                    if !data.helpLinkLabel.isEmpty, !data.helpLinkUrl.isEmpty {
                        Button(data.helpLinkLabel, action: onHelp)
                            .buttonStyle(.link)
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(40)
        }
    }
}

#Preview("First crash") {
    RendererCrashView(
        data: CrashPageData(dictionary: [
            "title": "Aw, Snap!",
            "message": "Something went wrong while displaying this webpage.",
            "buttonLabel": "Reload",
            "helpLinkLabel": "Learn more",
            "errorCodeText": "Error code: SIGSEGV",
            "helpLinkUrl": "https://phibrowser.com/help/",
            "showFeedbackButton": NSNumber(value: false),
            "tips": [],
        ]),
        onPrimaryAction: {},
        onHelp: {}
    )
    .frame(width: 760, height: 520)
}

#Preview("Repeated crash") {
    RendererCrashView(
        data: CrashPageData(dictionary: [
            "title": "Aw, Snap!",
            "message": "Something went wrong while displaying this webpage.",
            "buttonLabel": "Send feedback",
            "helpLinkLabel": "Learn more",
            "errorCodeText": "",
            "helpLinkUrl": "https://phibrowser.com/help/",
            "showFeedbackButton": NSNumber(value: true),
            "tips": [
                "Try reloading the page.",
                "Open the page in a new window.",
                "Check your internet connection.",
            ],
        ]),
        onPrimaryAction: {},
        onHelp: {}
    )
    .frame(width: 760, height: 520)
}
