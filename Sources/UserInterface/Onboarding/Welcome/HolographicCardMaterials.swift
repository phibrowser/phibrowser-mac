// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Cocoa
import ImageIO
import UniformTypeIdentifiers

/// Only the three discrete selections vary. Rendering parameters are the supplied
/// frontend's defaults, independent of selection and of persisted browser settings.
struct HolographicCardStyle: Codable, Equatable, Hashable, Sendable {
    enum Palette: String, Codable, CaseIterable, Sendable {
        case silver, green, aqua, blue, violet, pink, coral, gold

        var themeID: String {
            switch self {
            case .silver: return "pure"
            case .green: return "mint"
            case .aqua: return "aqua"
            case .blue: return "mist"
            case .violet: return "iris"
            case .pink: return "petal"
            case .coral: return "coral"
            case .gold: return "amber"
            }
        }

        init(themeID: String) {
            self = Self.allCases.first { $0.themeID == themeID } ?? .silver
        }

        /// Primary, secondary and accent, copied from app.js presets.
        var colors: [Int] {
            switch self {
            case .silver: return [0xBFC3C9, 0xE8EAEC, 0x929AA6]
            case .green: return [0x8DDA83, 0xEBDD87, 0x43BFC5]
            case .aqua: return [0x72D9DF, 0xB5E9A1, 0x8980E5]
            case .blue: return [0x63CFFD, 0x83E4C5, 0xA777E8]
            case .violet: return [0x887EFA, 0xE3A0D7, 0x54C8DE]
            case .pink: return [0xDB79E5, 0xF5B98D, 0x818CEB]
            case .coral: return [0xF9857B, 0xF5D781, 0xBF75D4]
            case .gold: return [0xF6D879, 0xA6DFBB, 0xE88B9E]
            }
        }
    }

    enum Texture: String, Codable, CaseIterable, Sendable {
        case arcs, waves, guilloche, brushed, diamond, stardust
    }

    enum Ornament: String, Codable, CaseIterable, Sendable {
        case lace, lotus, periodic, modulated, epicycloid, none
        var enhanced: Bool { self == .periodic || self == .modulated || self == .epicycloid }
    }

    var palette: Palette = .silver
    var texture: Texture = .arcs
    var ornament: Ornament = .lace
    static let `default` = Self()
    static let gradientAngle: CGFloat = 200
    static let textureOpacity: Float = 0.72
    static let iridescenceOpacity: Float = 0.78
    static let textureContrast: CGFloat = 1.18

    static func random<R: RandomNumberGenerator>(using generator: inout R) -> Self {
        Self(palette: Palette.allCases.randomElement(using: &generator)!,
             texture: Texture.allCases.randomElement(using: &generator)!,
             ornament: Ornament.allCases.filter { $0 != .none }.randomElement(using: &generator)!)
    }

    static func random() -> Self {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }
}

enum HolographicCardArtwork {
    static let size = CGSize(width: 292, height: 423)
    static let rect = CGRect(origin: .zero, size: size)

    static let ticketPath: CGPath = {
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: 28, cornerHeight: 28)
        return path
    }()

    // Vector outline from the supplied Phi artwork, retained as geometry.
    static let logoPath: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 696.692, y: 392.315))
        let curves: [[CGFloat]] = [
            [696.692,298.625,620.397,222.389,526.566,222.389], [414.639,222.389,323.463,313.426,323.463,425.336],
            [323.463,558.679,432.036,667.169,565.482,667.169], [724.219,667.169,853.333,538.224,853.333,379.539],
            [853.333,191.392,700.115,38.2222,511.685,38.2222], [288.32,38.2222,106.667,219.736,106.667,442.929],
            [106.667,701.308,312.424,912.562,568.905,921.778]
        ]
        for c in curves { p.addCurve(to: CGPoint(x: c[4], y: c[5]), control1: CGPoint(x: c[0], y: c[1]), control2: CGPoint(x: c[2], y: c[3])) }
        p.addLine(to: CGPoint(x: 568.905, y: 701.727))
        p.addLine(to: CGPoint(x: 565.552, y: 701.727))
        let inner: [[CGFloat]] = [
            [413.033,701.727,288.949,577.738,288.949,425.336], [288.949,294.437,395.566,187.832,526.636,187.832],
            [639.541,187.832,731.346,279.566,731.346,392.315], [731.346,488.727,653.584,566.987,557.447,568.453],
            [507.055,568.453,463.896,527.946,463.896,476.579], [463.896,426.174,505.187,384.426,556.12,384.426],
            [607.053,384.426,648.344,425.685,648.344,476.579], [648.344,485.794,645.619,494.172,643.104,502.55],
            [675.522,476.509,696.762,437.065,696.762,392.315]
        ]
        for c in inner { p.addCurve(to: CGPoint(x: c[4], y: c[5]), control1: CGPoint(x: c[0], y: c[1]), control2: CGPoint(x: c[2], y: c[3])) }
        p.closeSubpath()
        var transform = CGAffineTransform(translationX: size.width * 0.064711, y: size.height * 0.06)
        transform = transform.scaledBy(x: size.width * 0.1376 / 960, y: size.width * 0.1376 / 960)
        return p.copy(using: &transform)!
    }()

    /// CGPath lacks Sendable in the SDK. Only an immutable copy leaves the producer;
    /// no mutable path is shared. Remove this wrapper when CGPath gains Sendable.
    struct ImmutablePath: @unchecked Sendable {
        let value: CGPath

        init(_ path: CGPath) {
            value = path.copy()!
        }
    }

    struct Material: Sendable {
        let grain: CGImage?
        let foil: CGImage?
        let seal: ImmutablePath
    }

    /// Serializes cache misses off the main actor, sharing immutable artwork across cards.
    actor Cache {
        // Bump the version when drawing formulas, colors, or serialization change.
        private let directory: URL
        private var grainImage: CGImage?
        private var textures: [HolographicCardStyle.Texture: CGImage] = [:]
        private var ornaments: [HolographicCardStyle.Ornament: ImmutablePath] = [:]

        init(directory: URL = URL(fileURLWithPath: FileSystemUtils.cacheDirctory(), isDirectory: true)
            .appendingPathComponent("HolographicCardArtwork", isDirectory: true)) {
            self.directory = directory.appendingPathComponent("v1-584x846", isDirectory: true)
        }

        func material(for style: HolographicCardStyle) -> Material {
            assert(!Thread.isMainThread, "Card artwork must be prepared off the main thread.")
            if grainImage == nil {
                grainImage = loadImage("grain.png")
                if grainImage == nil, let image = HolographicCardArtwork.grain {
                    grainImage = image
                    storeImage(image, name: "grain.png")
                }
            }
            return Material(grain: grainImage, foil: foil(style.texture), seal: sealPath(style.ornament))
        }

        func foil(_ texture: HolographicCardStyle.Texture) -> CGImage? {
            if let cached = textures[texture] { return cached }
            let name = "foil-\(texture.rawValue).png"
            if let image = loadImage(name) {
                textures[texture] = image
                return image
            }
            let image = makeFoil(texture)
            textures[texture] = image
            if let image { storeImage(image, name: name) }
            return image
        }

        func sealPath(_ ornament: HolographicCardStyle.Ornament) -> ImmutablePath {
            if let cached = ornaments[ornament] { return cached }
            let name = "seal-\(ornament.rawValue).plist"
            if let data = loadData(name),
               let geometry = try? PropertyListDecoder().decode(SealGeometry.self, from: data),
               let path = geometry.path(for: ornament) {
                let cached = ImmutablePath(path)
                ornaments[ornament] = cached
                return cached
            }
            let path = ImmutablePath(makeSealPath(ornament))
            ornaments[ornament] = path
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            if let data = try? encoder.encode(SealGeometry(path.value)) { storeData(data, name: name) }
            return path
        }

        private func loadData(_ name: String) -> Data? {
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, size > 0, size <= 4 * 1024 * 1024 else { return nil }
            return try? Data(contentsOf: url)
        }

        private func storeData(_ data: Data, name: String) {
            // A cache is disposable: unavailable storage must not prevent presentation.
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            } catch { }
        }

        private func loadImage(_ name: String) -> CGImage? {
            guard let data = loadData(name),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == Int(size.width * 2),
                  properties[kCGImagePropertyPixelHeight] as? Int == Int(size.height * 2) else { return nil }
            // Decode here on the cache actor rather than lazily on the first UI draw.
            return CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }

        private func storeImage(_ image: CGImage, name: String) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            storeData(data as Data, name: name)
        }
    }

    /// The seal formulas produce only polylines. Persist their points, preserving
    /// vector masks and moving highlights without rerunning the trigonometry.
    private struct SealGeometry: Codable {
        var contours: [[CGPoint]] = []

        init(_ path: CGPath) {
            var contours: [[CGPoint]] = []
            path.applyWithBlock { element in
                switch element.pointee.type {
                case .moveToPoint: contours.append([element.pointee.points[0]])
                case .addLineToPoint: contours[contours.count - 1].append(element.pointee.points[0])
                default: break
                }
            }
            self.contours = contours
        }

        func path(for ornament: HolographicCardStyle.Ornament) -> CGPath? {
            let closed = ornament == .lace || ornament == .lotus
            let count = ornament == .none ? 0 : (closed ? 6 : 1)
            let pointsPerContour = closed ? 2881 : (ornament == .epicycloid ? 16 : 20) * 720 + 1
            guard contours.count == count,
                  contours.allSatisfy({ $0.count == pointsPerContour && $0.allSatisfy {
                      $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 200 && abs($0.y) <= 200
                  } }) else { return nil }
            let path = CGMutablePath()
            for points in contours {
                path.addLines(between: points)
                if closed { path.closeSubpath() }
            }
            return path
        }
    }

    static let cache = Cache()

    private static func makeSealPath(_ ornament: HolographicCardStyle.Ornament) -> CGPath {
        let path = CGMutablePath()
        let closed = ornament == .lace || ornament == .lotus
        let steps = closed ? 2880 : (ornament == .epicycloid ? 16 : 20) * 720
        if ornament != .none {
            for line in 0..<(closed ? 6 : 1) {
                for sample in 0...steps {
                    let u = CGFloat(sample) / CGFloat(steps) * .pi * 2
                    var x: CGFloat = 0, y: CGFloat = 0
                    if closed {
                        let lotus = ornament == .lotus
                        let phase = lotus ? u + .pi / 10 : u
                        let radius = lotus ? 28.5 + (12.3 + CGFloat(line) * 0.46) * cos(10 * u)
                            : 32 + (9.5 + CGFloat(line) * 0.48) * cos(18 * u)
                        let tangent = lotus ? (10.5 + CGFloat(line) * 0.32) * sin(10 * u)
                            : (5.8 + CGFloat(line) * 0.28) * sin(18 * u)
                        x = radius * cos(phase) - tangent * sin(phase)
                        y = radius * sin(phase) + tangent * cos(phase)
                    } else if ornament == .epicycloid {
                        let r: CGFloat = 6.2, bigR: CGFloat = 9.4, t = u * 16
                        let scale = 44 / (bigR + 2 * r), k = (bigR + r) / r
                        x = scale * ((bigR + r) * cos(t) - r * cos(k * t))
                        y = scale * ((bigR + r) * sin(t) - r * sin(k * t))
                    } else {
                        let p: CGFloat = ornament == .modulated ? 1.5 : 0
                        let c: CGFloat = ornament == .modulated ? 0.02 : 0
                        let t = u * 20
                        let radius = 44 / (10 + abs(p)) * (8 - 2 * cos(6 * t) - p * cos(c * t))
                        x = radius * cos(0.99 * t)
                        y = radius * sin(0.99 * t)
                    }
                    // Match the SVG's three-decimal path serialization.
                    let point = CGPoint(x: ((50 + x) * 1000).rounded() / 1000,
                                        y: ((50 + y) * 1000).rounded() / 1000)
                    if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                if closed { path.closeSubpath() }
            }
        }
        return path
    }

    private static func makeFoil(_ texture: HolographicCardStyle.Texture) -> CGImage? {
        // The reference canvas has a fixed DPR of 2.
        let raw = bitmap(scale: 2) { context in
            context.setFillColor(hex(0x898989))
            context.fill(rect)
            var seed = 91
            func random() -> CGFloat {
                seed = seed * 16807 % 2147483647
                return CGFloat(seed - 1) / 2147483646
            }
            func engrave(_ path: CGPath, light: CGFloat = 0.8, dark: CGFloat = 0.6, width: CGFloat = 0.65) {
                context.saveGState()
                context.translateBy(x: 0.6, y: 0.7)
                context.addPath(path)
                context.setLineWidth(width)
                context.setStrokeColor(hex(0x0f141e, alpha: dark))
                context.strokePath()
                context.restoreGState()
                context.addPath(path)
                context.setLineWidth(width)
                context.setStrokeColor(hex(0xffffff, alpha: light))
                context.strokePath()
            }
            func diamond(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x, y: y - r))
                p.addLine(to: CGPoint(x: x + r, y: y))
                p.addLine(to: CGPoint(x: x, y: y + r))
                p.addLine(to: CGPoint(x: x - r, y: y))
                p.closeSubpath()
                return p
            }
            switch texture {
            case .arcs:
                let radius: CGFloat = 32, spacing: CGFloat = 51.2, rowHeight: CGFloat = 19.2
                var row = -2
                while CGFloat(row) * rowHeight < size.height + radius {
                    let cy = CGFloat(row) * rowHeight, offset: CGFloat = row % 2 == 0 ? 0 : spacing / 2
                    for cx in stride(from: -spacing + offset, to: size.width + spacing, by: spacing) {
                        context.saveGState()
                        context.addArc(center: CGPoint(x: cx, y: cy), radius: radius, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
                        context.closePath()
                        context.clip()
                        gradient(context, colors: [0xa0a0a0, 0x858585, 0x969696].map { hex($0) }, locations: [0, 0.5, 1],
                                 start: CGPoint(x: cx - radius, y: cy - radius), end: CGPoint(x: cx + radius, y: cy))
                        for r in stride(from: CGFloat(4), to: radius, by: 2.16) {
                            let path = CGMutablePath()
                            path.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
                            engrave(path, light: 0.85, dark: 0.65, width: 0.56)
                        }
                        context.restoreGState()
                    }
                    row += 1
                }
            case .waves:
                for row in stride(from: CGFloat(-45), to: size.height + 45, by: 3.1) {
                    let p = CGMutablePath()
                    for x in stride(from: CGFloat(-5), to: size.width + 5, by: 2) {
                        let y = row + 14 * sin(x * 0.031 + row * 0.008) + 7 * sin(x * 0.063 - row * 0.012)
                        let point = CGPoint(x: x, y: y)
                        if x == -5 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                    engrave(p)
                }
            case .guilloche:
                for cy in stride(from: CGFloat(35), to: size.height + 65, by: 85) {
                    for cx in stride(from: CGFloat(30), to: size.width + 65, by: 85) {
                        for r in stride(from: CGFloat(8), to: 57, by: 2.4) {
                            let p = CGMutablePath()
                            for t in stride(from: CGFloat(0), through: .pi * 2 + 0.02, by: 0.02) {
                                let radius = r + 5 * sin(8 * t + r * 0.07)
                                let point = CGPoint(x: cx + radius * cos(t), y: cy + radius * sin(t))
                                if t == 0 { p.move(to: point) } else { p.addLine(to: point) }
                            }
                            engrave(p, light: 0.7, dark: 0.5, width: 0.5)
                        }
                    }
                }
            case .brushed:
                for y in stride(from: CGFloat(0), to: size.height, by: 0.8) {
                    let start = random() * size.width * 0.25, length = size.width * (0.35 + random() * 0.7)
                    let p = CGMutablePath()
                    p.move(to: CGPoint(x: start, y: y)); p.addLine(to: CGPoint(x: start + length, y: y + 1.5))
                    engrave(p, light: 0.15 + random() * 0.35, dark: 0.12 + random() * 0.3, width: 0.4)
                }
            case .diamond:
                for y in stride(from: CGFloat(-24), to: size.height + 24, by: 24) {
                    for x in stride(from: CGFloat(-24), to: size.width + 24, by: 24) {
                        context.saveGState()
                        context.addPath(diamond(x + 12, y + 12, 12)); context.clip()
                        gradient(context, colors: [0xc2c2c2, 0x858585, 0x626262].map { hex($0) }, locations: [0, 0.5, 1],
                                 start: CGPoint(x: x, y: y), end: CGPoint(x: x + 24, y: y + 24))
                        context.restoreGState()
                        for r in stride(from: CGFloat(3), through: 12, by: 3) {
                            engrave(diamond(x + 12, y + 12, r), light: 0.7, dark: 0.5, width: 0.55)
                        }
                    }
                }
            case .stardust:
                for _ in 0..<Int(ceil(size.width * size.height / 64)) {
                    let x = random() * size.width, y = random() * size.height, s = 0.65 + random() * 1.05
                    context.setFillColor(hex(0x0c121c, alpha: 0.55 + random() * 0.3))
                    context.fill(CGRect(x: x + 0.6, y: y + 0.75, width: s, height: s))
                    context.setFillColor(hex(0xffffff, alpha: 0.75 + random() * 0.25))
                    context.fill(CGRect(x: x, y: y, width: s, height: s))
                }
                for _ in 0..<Int(ceil(size.width * size.height / 5200)) {
                    let x = random() * size.width, y = random() * size.height, r = 1.5 + random() * 2
                    let p = CGMutablePath()
                    p.move(to: CGPoint(x: x - r, y: y)); p.addLine(to: CGPoint(x: x + r, y: y))
                    p.move(to: CGPoint(x: x, y: y - r)); p.addLine(to: CGPoint(x: x, y: y + r))
                    engrave(p, light: 0.95, dark: 0.7, width: 0.8)
                }
            }
        }
        guard let raw, let data = raw.dataProvider?.data else { return nil }
        var pixels = Array(data as Data)
        // CSS contrast(1.18) operates on sRGB components around 0.5.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            for c in 0..<3 {
                let value = (CGFloat(pixels[i + c]) / 255 - 0.5) * HolographicCardStyle.textureContrast + 0.5
                pixels[i + c] = UInt8((min(1, max(0, value)) * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: raw.width, height: raw.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: raw.bytesPerRow, space: raw.colorSpace!, bitmapInfo: raw.bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return image
    }

    /// SVG feTurbulence defaults: seed 0, fractalNoise, frequency .85,
    /// three octaves, stitched 180 x 180 tile and path opacity .8.
    private static let grain: CGImage? = {
        var seed = 1
        func random() -> Int { seed = seed * 16807 % 2147483647; return seed }
        var permutation = Array(0..<256)
        var vectors = Array(repeating: Array(repeating: CGPoint.zero, count: 256), count: 4)
        for channel in 0..<4 {
            for i in 0..<256 {
                let x = Double(random() % 512 - 256) / 256
                let y = Double(random() % 512 - 256) / 256
                let length = max(0.000001, hypot(x, y))
                vectors[channel][i] = CGPoint(x: x / length, y: y / length)
            }
        }
        for i in stride(from: 255, through: 1, by: -1) { permutation.swapAt(i, random() % 256) }
        func noise(_ x: CGFloat, _ y: CGFloat, channel: Int, period: Int) -> CGFloat {
            let ix = Int(floor(x)), iy = Int(floor(y))
            let fx = x - CGFloat(ix), fy = y - CGFloat(iy)
            func wrap(_ n: Int) -> Int { ((n % period + period) % period) & 255 }
            func dot(_ dx: Int, _ dy: Int) -> CGFloat {
                let index = permutation[(permutation[wrap(ix + dx)] + wrap(iy + dy)) & 255]
                let v = vectors[channel][index]
                return v.x * (fx - CGFloat(dx)) + v.y * (fy - CGFloat(dy))
            }
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            let a = dot(0, 0) + sx * (dot(1, 0) - dot(0, 0))
            let b = dot(0, 1) + sx * (dot(1, 1) - dot(0, 1))
            return a + sy * (b - a)
        }
        let width = 360, height = 360
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var channels = [CGFloat](repeating: 0, count: 4)
                for channel in 0..<4 {
                    var value: CGFloat = 0, frequency: CGFloat = 0.85, amplitude: CGFloat = 1, period = 153
                    for _ in 0..<3 {
                        value += noise((CGFloat(x) + 0.5) / 2 * frequency, (CGFloat(y) + 0.5) / 2 * frequency,
                                       channel: channel, period: period) / amplitude
                        frequency *= 2; amplitude *= 2; period *= 2
                    }
                    channels[channel] = min(1, max(0, (value + 1) / 2))
                }
                let alpha = channels[3] * 0.8
                for channel in 0..<3 {
                    let linear = channels[channel]
                    let srgb = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
                    bytes[(y * width + x) * 4 + channel] = UInt8((srgb * alpha * 255).rounded())
                }
                bytes[(y * width + x) * 4 + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let tile = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return bitmap(scale: 2) { context in
            for y in stride(from: CGFloat(0), to: size.height, by: 180) {
                for x in stride(from: CGFloat(0), to: size.width, by: 180) {
                    context.draw(tile, in: CGRect(x: x, y: y, width: 180, height: 180))
                }
            }
        }
    }()

    nonisolated static func hex(_ value: Int, alpha: CGFloat = 1) -> CGColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: alpha).cgColor
    }

    static func gradient(_ context: CGContext, colors: [CGColor], locations: [CGFloat], start: CGPoint, end: CGPoint) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations) else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func bitmap(scale: CGFloat = 3, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return context.makeImage()
    }
}
