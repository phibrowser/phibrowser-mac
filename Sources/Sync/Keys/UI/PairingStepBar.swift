// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Two-step indicator (§6.3), with current/complete/upcoming states and checkmarks for completed steps.
/// Read-only: Back in the footer is the sole navigation action. The repository has no reusable step/wizard
/// component.
struct PairingStepBar: View {
    let step: PairingWizardStep

    private struct Segment: Identifiable {
        let id: Int
        let title: String
        let isComplete: Bool
        let isCurrent: Bool
    }

    private var segments: [Segment] {
        [Segment(id: 1,
                 title: NSLocalizedString("sync.pairing.stepBar.profiles",
                                          value: "Profiles",
                                          comment: "Sync setup step bar - label of the profile matching step"),
                 isComplete: step == .spaces, isCurrent: step == .profiles),
         Segment(id: 2,
                 title: NSLocalizedString("sync.pairing.stepBar.spaces",
                                          value: "Spaces",
                                          comment: "Sync setup step bar - label of the Space matching step"),
                 isComplete: false, isCurrent: step == .spaces)]
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(segments) { segment in
                if segment.id > 1 {
                    Rectangle()
                        .themedFill(.border)
                        .frame(height: 1)
                        .frame(maxWidth: 64)
                }
                HStack(spacing: 6) {
                    marker(segment)
                    Text(segment.title)
                        .font(.callout)
                        .themedForeground(segment.isCurrent || segment.isComplete
                                          ? .textPrimaryStrong : .textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(
                    format: NSLocalizedString("sync.pairing.stepBar.position",
                                              value: "Step %1$d of %2$d: %3$@",
                                              comment: "Sync setup step bar - VoiceOver label; %1$d is the current step, %2$d the step count, %3$@ the step name"),
                    segment.id, segments.count, segment.title))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func marker(_ segment: Segment) -> some View {
        if segment.isComplete {
            Image(systemName: "checkmark")
                .font(.caption)
                .themedForeground(.textPrimaryStrong)
        } else {
            Text(segment.id, format: .number)
                .font(.caption)
                .themedForeground(segment.isCurrent ? .textPrimaryStrong : .textSecondary)
        }
    }
}
