// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// 两段步骤条（§6.3）。三态：current / complete / upcoming，complete 段的序号换成
/// `checkmark`。**只读，不可点**——回退走页脚的 Back，一个动作只有一个入口。
///
/// 仓库里没有任何 step / wizard 形状的组件可复用，所以这是第一个。
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
                 title: NSLocalizedString("Profiles",
                                          comment: "Settings - Tab title for profiles management"),
                 isComplete: step == .spaces, isCurrent: step == .profiles),
         Segment(id: 2,
                 title: NSLocalizedString("Spaces",
                                          comment: "Settings - Tab title for profiles and spaces management"),
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
                    format: NSLocalizedString("Step %1$d of %2$d: %3$@",
                                              comment: "Pairing wizard - step bar position, for VoiceOver"),
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
            Text("\(segment.id)")
                .font(.caption)
                .themedForeground(segment.isCurrent ? .textPrimaryStrong : .textSecondary)
        }
    }
}
