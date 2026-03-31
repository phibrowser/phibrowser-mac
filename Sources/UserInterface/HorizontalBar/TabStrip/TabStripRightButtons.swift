// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Right-side buttons area for the TabStrip bar
/// Contains CardEntryButton and future buttons
struct TabStripRightButtons: View {
    @ObservedObject var cardManager: NotificationCardManager
    let onCardEntryTap: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            // Buttons are laid out from right to left (trailing alignment)
            // Future buttons can be added here (will appear to the left of CardEntryButton)
            
            if showCardEntry {
                CardEntryButton(action: onCardEntryTap)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8)),
                            removal: .opacity
                        )
                    )
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showCardEntry)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
//        .offset(y: -4) // Visual alignment adjustment
        .ignoresSafeArea()
    }
    
    private var showCardEntry: Bool {
        cardManager.latestCard != nil
    }
}
