// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Step indicator (§6.3) over the pages this load shows (PairingWizardViewModel.visibleSteps), with
/// current/complete/upcoming states and checkmarks for completed steps. Read-only: Back in the footer is the
/// sole navigation action. The repository has no reusable step/wizard component.
///
/// The bar keeps one height whether it lists pages or none (while loading, or when the wizard completes on
/// its own), so the content below never jumps.
struct PairingStepBar: View {
    let steps: [PairingWizardStep]
    /// The page the user is on; nil or a page not in `steps` marks nothing current.
    let current: PairingWizardStep?

    struct Segment: Identifiable, Equatable {
        /// 1-based position, also the number shown before the title.
        let id: Int
        let step: PairingWizardStep
        let isComplete: Bool
        let isCurrent: Bool
    }

    /// Segments before the current page are complete; the rest are upcoming.
    static func segments(steps: [PairingWizardStep], current: PairingWizardStep?) -> [Segment] {
        let currentIndex = current.flatMap { steps.firstIndex(of: $0) }
        return steps.enumerated().map { index, step in
            Segment(id: index + 1, step: step,
                    isComplete: currentIndex.map { index < $0 } ?? false,
                    isCurrent: index == currentIndex)
        }
    }

    static func title(for step: PairingWizardStep) -> String {
        switch step {
        case .method:
            return NSLocalizedString("sync.pairing.stepBar.method",
                                     value: "Sync method",
                                     comment: "Sync setup step bar - label of the step that chooses how this Mac joins the account's data")
        case .profiles:
            return NSLocalizedString("sync.pairing.stepBar.profiles",
                                     value: "Profiles",
                                     comment: "Sync setup step bar - label of the profile matching step")
        case .spaces:
            return NSLocalizedString("sync.pairing.stepBar.spaces",
                                     value: "Spaces",
                                     comment: "Sync setup step bar - label of the Space matching step")
        case .confirm:
            return NSLocalizedString("sync.pairing.stepBar.confirm",
                                     value: "Confirm",
                                     comment: "Sync setup step bar - label of the step that confirms replacing this Mac's data with the account's")
        }
    }

    private var segments: [Segment] { Self.segments(steps: steps, current: current) }

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
                    Text(Self.title(for: segment.step))
                        .font(.callout)
                        .themedForeground(segment.isCurrent || segment.isComplete
                                          ? .textPrimaryStrong : .textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(
                    format: NSLocalizedString("sync.pairing.stepBar.position",
                                              value: "Step %1$d of %2$d: %3$@",
                                              comment: "Sync setup step bar - VoiceOver label; %1$d is the current step, %2$d the step count, %3$@ the step name"),
                    segment.id, segments.count, Self.title(for: segment.step)))
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Self.minContentHeight)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    /// Fits one callout line, so an empty bar is as tall as a populated one; larger text may still grow it.
    private static let minContentHeight: CGFloat = 20

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
