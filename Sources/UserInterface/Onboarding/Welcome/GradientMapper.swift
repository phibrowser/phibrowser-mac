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

    static func apply(to bwImage: NSImage, using gradientStrip: CIImage) -> NSImage? {
           return autoreleasepool { () -> NSImage? in
               guard let cgImage = bwImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                   return nil
               }
               
               let input = CIImage(cgImage: cgImage)
               
               guard let filter = CIFilter(name: "CIColorMap") else { return nil }
               filter.setValue(input, forKey: kCIInputImageKey)
               filter.setValue(gradientStrip, forKey: "inputGradientImage")
               
               guard let output = filter.outputImage else { return nil }
               
               guard let finalCGImage = sharedContext.createCGImage(output, from: output.extent) else {
                   return nil
               }
               
               return NSImage(cgImage: finalCGImage, size: bwImage.size)
           }
       }

}
