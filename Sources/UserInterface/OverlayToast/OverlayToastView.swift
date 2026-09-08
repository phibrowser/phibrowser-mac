// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

struct OverlayToastView: View {
    let toast: OverlayToastItem

    private let cornerRadius: CGFloat = 10
    private let maxWidth: CGFloat = 360
    @State private var naturalContentWidth: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            naturalWidthProbe
            toastContent
                .frame(width: preferredContentWidth, alignment: .leading)
        }
        .onPreferenceChange(OverlayToastNaturalWidthKey.self) { width in
            naturalContentWidth = width
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlayToastBackground(cornerRadius: cornerRadius)
        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overlayToast.container")
    }

    private var toastContent: some View {
        HStack(alignment: .center, spacing: 12) {
            toastText
            if let url = toast.shareURL {
                OverlayToastShareButton(url: url, toastID: toast.id)
                    .fixedSize()
            }

            if let action = toast.action {
                Button {
                    action.handler()
                    OverlayToastCenter.shared.dismiss(id: toast.id)
                } label: {
                    Text(action.title)
                        .font(.system(size: 12, weight: .semibold))
                        .overlayToastPrimaryStyle()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("overlayToast.action")
            }
        }
    }

    private var toastText: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            if let titleText {
                Text(titleText)
                    .font(.system(size: 13, weight: .medium))
                    .overlayToastPrimaryStyle()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overlayToast.title")
            }

            if let messageText {
                if titleText == nil {
                    Text(messageText)
                        .font(.system(size: 13, weight: .regular))
                        .overlayToastPrimaryStyle()
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("overlayToast.message")
                } else {
                    Text(messageText)
                        .font(.system(size: 12))
                        .overlayToastSecondaryStyle()
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("overlayToast.message")
                }
            }
        }
    }

    private var naturalWidthProbe: some View {
        toastContent
            .fixedSize(horizontal: true, vertical: true)
            .hidden()
            .accessibilityHidden(true)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: OverlayToastNaturalWidthKey.self,
                        value: geometry.size.width
                    )
                }
            )
            .frame(width: 0, height: 0)
    }

    private var preferredContentWidth: CGFloat {
        guard naturalContentWidth > 0 else {
            return maxWidth
        }
        return min(ceil(naturalContentWidth), maxWidth)
    }

    private var titleText: String? {
        let title = toast.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private var messageText: String? {
        guard let message = toast.message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty
        else {
            return nil
        }
        return message
    }

    private var contentSpacing: CGFloat {
        titleText == nil || messageText == nil ? 0 : 4
    }
}

private struct OverlayToastNaturalWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct OverlayToastShareButton: NSViewRepresentable {
    let url: URL
    let toastID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, toastID: toastID)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: NSLocalizedString(
                "browser.highlightLink.shareButton",
                value: "Share",
                comment: "Highlight link copy confirmation - Button that opens the system sharing menu for the copied link"
            ),
            target: context.coordinator,
            action: #selector(Coordinator.share(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityIdentifier("overlayToast.shareButton")
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.url = url
        context.coordinator.toastID = toastID
    }

    final class Coordinator: NSObject {
        var url: URL
        var toastID: UUID

        init(url: URL, toastID: UUID) {
            self.url = url
            self.toastID = toastID
        }

        @MainActor @objc func share(_ sender: NSButton) {
            guard sender.window != nil else { return }
            let id = toastID
            OverlayToastCenter.shared.pauseDismissal(id: id)
            defer { OverlayToastCenter.shared.dismiss(id: id) }

            let menu = PageSharingPresenter.shareMenu(for: url)
            let point = NSPoint(x: sender.bounds.minX, y: sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY)
            menu.popUp(positioning: nil, at: point, in: sender)
        }
    }
}

private struct OverlayToastLegacyBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ColoredVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.backgroundColor = NSColor.white
        view.colorAlphaComponent = 0.5
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private extension View {
    @ViewBuilder
    func overlayToastBackground(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(OverlayToastLegacyBackgroundView())
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    func overlayToastPrimaryStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.foregroundStyle(.primary)
        } else {
            self.foregroundColor(Color.phiPrimary.opacity(0.85))
        }
    }

    @ViewBuilder
    func overlayToastSecondaryStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.foregroundStyle(.secondary)
        } else {
            self.foregroundColor(Color.phiPrimary.opacity(0.5))
        }
    }
}

#if DEBUG
struct OverlayToastView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.gray.opacity(0.2)
            OverlayToastView(
                toast: OverlayToastItem(
                    id: UUID(),
                    title: "Bookmark saved",
                    message: "The current page was added to Favorites.",
                    duration: 3,
                    placement: .topCenter
                )
            )
        }
        .frame(width: 600, height: 220)
    }
}
#endif
