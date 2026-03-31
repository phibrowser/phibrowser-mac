// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct LayoutModeSettingView: View {
    @AppStorage(PhiPreferences.GeneralSettings.layoutModeKey)
    private var layoutModeRawValue: String = PhiPreferences.GeneralSettings.loadLayoutMode().rawValue

    private var selectedLayoutMode: Binding<LayoutMode> {
        Binding(
            get: {
                LayoutMode(rawValue: layoutModeRawValue) ?? PhiPreferences.GeneralSettings.loadLayoutMode()
            },
            set: { mode in
                layoutModeRawValue = mode.rawValue
                PhiPreferences.GeneralSettings.saveLayoutMode(mode)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(NSLocalizedString("Layout Mode", comment: "General settings - Section title for layout configuration"))
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 16) {
                ForEach(LayoutMode.allCases) { mode in
                    GeneralSttingCardView(
                        image: Image(layoutImageResource(for: mode)),
                        action: { selectedLayoutMode.wrappedValue = mode },
                        selected: selectedLayoutMode.wrappedValue == mode,
                        title: mode.displayName
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func layoutImageResource(for mode: LayoutMode) -> ImageResource {
        switch mode {
        case .performance:
            return .tabLayoutPerformance
        case .balanced:
            return .tabLayoutBalanced
        case .comfortable:
            return .tabLayoutComfortable
        }
    }
}

struct GeneralSttingCardView: View {
    let image: Image
    let action: () -> Void
    let selected: Bool
    let title: String
    private let cardWidth: CGFloat = 122
    private let imageHeight: CGFloat = 72

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardWidth, height: imageHeight)
//                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .themedStroke(selected ? .themeColor : .border, lineWidth: selected ? 2 : 0)
                    }

                Text(title)
                    .font(.system(size: 11))
                    .themedForeground(.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: cardWidth)
            }
            .frame(width: cardWidth)
        }
        .buttonStyle(GeneralSettingCardButtonStyle())
    }
}

private struct GeneralSettingCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

#Preview {
    LayoutModeSettingView()
}
