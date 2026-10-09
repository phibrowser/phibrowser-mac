// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import UniformTypeIdentifiers

/// Presents export UI for the exact image copied by the screenshot service.
@MainActor
enum PageScreenshotPresenter {
    static func suggestedFileName(title: String) -> String {
        let fallback = NSLocalizedString("browser.screenshot.fileName", value: "Screenshot",
                                         comment: "Screenshot - Fallback JPEG file name when the page title is empty or unusable")
        let base = ReaderExportService.sanitizedBaseName(title: title, fallbackName: fallback)
        return "\(base).jpg"
    }

    static func showCopied(
        jpegData: Data, title: String, windowId: Int,
        toastCenter: OverlayToastCenter = .shared,
        save: @escaping @MainActor (Data, String, Int) -> Void = saveJPEG
    ) {
        let fileName = suggestedFileName(title: title)
        let action = OverlayToastAction(
            title: NSLocalizedString("browser.screenshot.saveAction", value: "Save",
                                     comment: "Screenshot - Button on the copied screenshot toast to save the JPEG to a file"),
            isBordered: true,
            handler: { save(jpegData, fileName, windowId) })
        toastCenter.show(
            title: NSLocalizedString("browser.screenshot.copied", value: "Full page screenshot copied",
                                     comment: "Screenshot - Success toast after copying the JPEG to the clipboard"),
            duration: 6, in: .windowId(windowId), action: action)
    }

    private static func saveJPEG(_ jpegData: Data, _ fileName: String, _ windowId: Int) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await Task.detached {
                        try jpegData.write(to: url, options: .atomic)
                    }.value
                } catch {
                    AppLogError("[Screenshot] JPEG export failed: \(error)")
                    OverlayToastCenter.shared.show(
                        title: NSLocalizedString("browser.screenshot.saveFailed", value: "Could not save the screenshot",
                                                 comment: "Screenshot - Error toast when writing the selected JPEG file fails"),
                        in: .windowId(windowId))
                }
            }
        }
        if let window = SpaceSessionControllersManager.shared.controller(for: windowId)?.window,
           window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
