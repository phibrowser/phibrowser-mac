// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

// Custom progress view with linear and circular styles.
// Features rounded line caps for a modern look.

import SwiftUI

enum PhiProgressStyle {
    case linear
    case circular
}

struct PhiProgressView: View {
    var progress: Double
    var style: PhiProgressStyle = .linear
    var progressColor: Color = .phiPrimary
    var trackColor: Color = Color.phiPrimary.opacity(0.15)
    var lineWidth: CGFloat = 3
    var showGradientFade: Bool = true
    
    var body: some View {
        switch style {
        case .linear:
            LinearProgressView(
                progress: progress,
                progressColor: progressColor,
                trackColor: trackColor,
                lineWidth: lineWidth,
                showGradientFade: showGradientFade
            )
        case .circular:
            CircularProgressView(
                progress: progress,
                progressColor: progressColor,
                trackColor: trackColor,
                lineWidth: lineWidth
            )
        }
    }
}

// MARK: - Linear Progress View

struct LinearProgressView: View {
    var progress: Double
    var progressColor: Color
    var trackColor: Color
    var lineWidth: CGFloat
    var showGradientFade: Bool
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let cornerRadius = height / 2
            let progressWidth = width * min(max(progress, 0), 1)
            
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: height)
                
                if progress > 0 {
                    if showGradientFade {
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: progressColor, location: 0),
                                .init(color: progressColor, location: max(0, 1 - (cornerRadius * 2 / max(progressWidth, 1)))),
                                .init(color: progressColor.opacity(0.3), location: 1)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: progressWidth, height: height)
                        .clipShape(Capsule())
                    } else {
                        Capsule()
                            .fill(progressColor)
                            .frame(width: progressWidth, height: height)
                    }
                }
            }
        }
    }
}

// MARK: - Circular Progress View

struct CircularProgressView: View {
    var progress: Double
    var progressColor: Color
    var trackColor: Color
    var lineWidth: CGFloat
    
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let adjustedLineWidth = lineWidth
            
            ZStack {
                Circle()
                    .stroke(
                        trackColor,
                        style: StrokeStyle(
                            lineWidth: adjustedLineWidth,
                            lineCap: .round
                        )
                    )
                
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(
                        progressColor,
                        style: StrokeStyle(
                            lineWidth: adjustedLineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.2), value: progress)
            }
            .frame(width: size, height: size)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

struct PhiLinearProgressViewStyle: ProgressViewStyle {
    var progressColor: Color = .phiPrimary
    var trackColor: Color = Color.phiPrimary.opacity(0.15)
    var lineWidth: CGFloat = 3
    var showGradientFade: Bool = true
    
    func makeBody(configuration: Configuration) -> some View {
        LinearProgressView(
            progress: configuration.fractionCompleted ?? 0,
            progressColor: progressColor,
            trackColor: trackColor,
            lineWidth: lineWidth,
            showGradientFade: showGradientFade
        )
    }
}

struct PhiCircularProgressViewStyle: ProgressViewStyle {
    var progressColor: Color = .phiPrimary
    var trackColor: Color = Color.phiPrimary.opacity(0.15)
    var lineWidth: CGFloat = 3
    
    func makeBody(configuration: Configuration) -> some View {
        CircularProgressView(
            progress: configuration.fractionCompleted ?? 0,
            progressColor: progressColor,
            trackColor: trackColor,
            lineWidth: lineWidth
        )
    }
}

extension ProgressViewStyle where Self == PhiLinearProgressViewStyle {
    static func phiLinear(
        progressColor: Color = .phiPrimary,
        trackColor: Color = Color.phiPrimary.opacity(0.15),
        lineWidth: CGFloat = 3,
        showGradientFade: Bool = true
    ) -> PhiLinearProgressViewStyle {
        PhiLinearProgressViewStyle(
            progressColor: progressColor,
            trackColor: trackColor,
            lineWidth: lineWidth,
            showGradientFade: showGradientFade
        )
    }
}

extension ProgressViewStyle where Self == PhiCircularProgressViewStyle {
    static func phiCircular(
        progressColor: Color = .phiPrimary,
        trackColor: Color = Color.phiPrimary.opacity(0.15),
        lineWidth: CGFloat = 3
    ) -> PhiCircularProgressViewStyle {
        PhiCircularProgressViewStyle(
            progressColor: progressColor,
            trackColor: trackColor,
            lineWidth: lineWidth
        )
    }
}

// MARK: - Preview

#if DEBUG
struct ProgressView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 40) {
            // Linear Progress Examples
            VStack(alignment: .leading, spacing: 16) {
                Text("Linear Progress")
                    .font(.headline)
                
                PhiProgressView(progress: 0.5, style: .linear,  progressColor: .red, trackColor: .black)
                    .frame(height: 2)
                
                
                PhiProgressView(progress: 0.75, style: .linear, showGradientFade: false)
                    .frame(height: 4)
                
                // Using as ProgressViewStyle
                ProgressView(value: 0.6)
                    .progressViewStyle(.phiLinear())
                    .frame(height: 4)
                
                // Paused state (orange)
                PhiProgressView(progress: 0.3, style: .linear, progressColor: .orange)
                    .frame(height: 4)
            }
            .padding()
            
            // Circular Progress Examples
            VStack(spacing: 16) {
                Text("Circular Progress")
                    .font(.headline)
                
                HStack(spacing: 24) {
                    PhiProgressView(progress: 0.25, style: .circular)
                        .frame(width: 40, height: 40)
                    
                    PhiProgressView(progress: 0.5, style: .circular)
                        .frame(width: 40, height: 40)
                    
                    PhiProgressView(progress: 0.75, style: .circular)
                        .frame(width: 40, height: 40)
                    
                    PhiProgressView(progress: 1.0, style: .circular)
                        .frame(width: 40, height: 40)
                }
                
                // Using as ProgressViewStyle
                ProgressView(value: 0.65)
                    .progressViewStyle(.phiCircular(lineWidth: 4))
                    .frame(width: 60, height: 60)
            }
            .padding()
        }
        .frame(width: 400)
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
}
#endif
