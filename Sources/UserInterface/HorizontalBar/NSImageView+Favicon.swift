// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

extension NSImageView {
    /// Loads a favicon with a globe fallback.
    func loadFavicon(from urlString: String?, cornerRadius: CGFloat = 4) {
        let defaultIcon = NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")

        guard let urlString = urlString,
              let url = URL(string: urlString) else {
            if self.image == nil {
                self.image = defaultIcon
            }
            return
        }

        self.setFavicon(for: url, configuration: .init(cornerRadius: cornerRadius, placeholder: nil)) { [weak self] result in
            switch result {
            case .failure:
                // Preserve any existing image instead of flashing back to the default icon.
                if self?.image == nil {
                    self?.image = defaultIcon
                }
            case .success:
                break
            }
        }
    }
}
