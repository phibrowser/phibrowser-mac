// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa
import CoreImage

class GradientMapper {
    private static let sharedContext: CIContext = {
        return CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false,
            .workingFormat: CIFormat.RGBA8
        ])

    }()

    /// `positions` are normalized into the `0...1` range.
    static func makeGradient(colors: [NSColor],
                             positions: [CGFloat]) -> NSGradient? {
        guard !colors.isEmpty,
              colors.count == positions.count else {
            return nil
        }

        return NSGradient(colors: colors,
                          atLocations: positions,
                          colorSpace: .deviceRGB)
    }

    // MARK: - Gradient Strip

    static func makeStrip(from gradient: NSGradient,
                          width: Int = 256) -> CIImage? {

        let height = 1
        let size = NSSize(width: width, height: height)
        
        let image = NSImage(size: size)
        image.lockFocus()
        
        let rect = NSRect(origin: .zero, size: size)
        gradient.draw(in: rect, angle: 0)
        
        image.unlockFocus()
        
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        
        guard let cg = bitmap.cgImage else {

            return nil
        }

        let ci = CIImage(cgImage: cg)
        return ci
    }

    static func apply(to bwImage: NSImage, using gradientStrip: CIImage, transparentBackground: Bool = false, coverageGain: CGFloat = 256) -> NSImage? {
           return autoreleasepool { () -> NSImage? in
               guard let cgImage = bwImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                   return nil
               }
               
               let source = CIImage(cgImage: cgImage)
               // Exclude the faint one-pixel frame encoded in these JPEG assets
               // before recovering low-luminance interior detail.
               let input = transparentBackground
                   ? source.cropped(to: source.extent.insetBy(dx: 2, dy: 2))
                   : source
               
               guard let filter = CIFilter(name: "CIColorMap") else { return nil }
               filter.setValue(input, forKey: kCIInputImageKey)
               filter.setValue(gradientStrip, forKey: "inputGradientImage")
               
               guard var output = filter.outputImage else { return nil }

               if transparentBackground {
                   // Coverage must reach opacity before the surface reaches its
                   // midtones; otherwise shadowed interiors fade into the window.
                   // Keep near-black backdrop/compression noise transparent.
                   let coverage = CIVector(x: coverageGain, y: 0, z: 0, w: 0)
                   let mask = input.applyingFilter("CIColorMatrix", parameters: [
                       "inputRVector": coverage,
                       "inputGVector": coverage,
                       "inputBVector": coverage,
                       "inputBiasVector": CIVector(x: -0.16, y: -0.16, z: -0.16, w: 0)
                   ]).applyingFilter("CIColorClamp")
                   output = output.applyingFilter("CIBlendWithMask", parameters: [
                       kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: input.extent),
                       kCIInputMaskImageKey: mask
                   ])
               }
               
               guard let finalCGImage = sharedContext.createCGImage(output, from: output.extent) else {
                   return nil
               }
               
               return NSImage(cgImage: finalCGImage, size: bwImage.size)
           }
       }

}
