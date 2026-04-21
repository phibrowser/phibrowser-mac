// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class ConchFrameAnimationBaseViewController: NSViewController {
    var imageNamagePrefix: String {
        get { "" }
    }
    
    /// Override to provide the optional pre-animation image prefix, such as `oobe-pre-`.
    var preAnimationImagePrefix: String {
        get { "" }
    }
    
    /// Number of pre-animation frames to load.
    var preAnimationFrameCount: Int {
        get { 24 }
    }
    
    var imageView = NSImageView()
    
    private let rows = 10
    private let cols = 10
    private let sensitivity: CGFloat = 20
    
    private var currentX: Int
    private var currentY: Int
    private let centerX: Int
    private let centerY: Int
    private var startPoint: NSPoint = .zero
    private var isDragging = false
    private var lastDisplayedX = -1
    private var lastDisplayedY = -1
    
    private var images: [[NSImage?]] = []
    private var coloredImages: [[NSImage?]] = []
    
    // MARK: - Pre-Animation
    /// Raw pre-animation frames loaded from asset names.
    private var preAnimationImages: [NSImage] = []
    /// Colorized variants of the pre-animation frames.
    private var coloredPreAnimationImages: [NSImage] = []
    private var isPreAnimationLoaded = false
    private var isFirstSliderChange = true
    private var hasPlayedPreAnimation = false
    
    private var loadedCount = 0
    private var currentColorValue: CGFloat = 0.0
    private var isColoringInProgress = false
    private let colorQueue = DispatchQueue(label: "com.phi.animationQueue", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "com.phi.animationState", qos: .userInitiated)
    private var preloadWorkItem: DispatchWorkItem?
    private var colorWorkItem: DispatchWorkItem?
    private var isTornDown = false
    
    // MARK: - Gradient Cache
    private var cachedGradient: NSGradient?
    private var cachedStrip: CIImage?
    private var cachedColorValue: CGFloat = -1.0
    
    // MARK: - Animation
    private var displayLink: CVDisplayLink?
    private var animationStartTime: CFTimeInterval = 0
    private var animationStartX = 0
    private var animationStartY = 0
    private var isAnimating = false
    private var isPlayingHintAnimation = false
    private var hintAnimationTimer: Timer?
    
    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        self.centerX = (cols + 1) / 2
        self.centerY = (rows + 1) / 2
        self.currentX = centerX
        self.currentY = centerY
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        AppLogDebug("[PreAnim] viewWillAppear - start")
        loadPreAnimationImages()
        preloadImages()
        AppLogDebug("[PreAnim] viewWillAppear - done")
    }
    
    func tearDown() {
        stopDragHintAnimation()
        
        stateQueue.sync {
            isTornDown = true
        }
        preloadWorkItem?.cancel()
        colorWorkItem?.cancel()
        DispatchQueue.main.async { [weak self] in
            self?.imageView.image = nil
        }
        stateQueue.sync {
            images.removeAll()
            coloredImages.removeAll()
            preAnimationImages.removeAll()
            coloredPreAnimationImages.removeAll()
            isPreAnimationLoaded = false
            loadedCount = 0
            isColoringInProgress = false
        }
    }
    
    // MARK: - Pre-Animation Loading
    
    private func loadPreAnimationImages() {
        let prefix = preAnimationImagePrefix
        guard !prefix.isEmpty else {
            AppLogDebug("[PreAnim] loadPreAnimationImages - prefix is empty, skip")
            return
        }
        
        let frameCount = preAnimationFrameCount
        guard frameCount > 0 else { return }
        
        AppLogDebug("[PreAnim] loadPreAnimationImages - start loading \(frameCount) frames with prefix: \(prefix)")
        
        var loadedImages: [NSImage] = []
        for i in 1...frameCount {
            if let image = NSImage(named: "\(prefix)\(i)") {
                loadedImages.append(image)
            } else {
                AppLogWarn("Failed to load pre-animation image: \(prefix)\(i)")
            }
        }
        
        stateQueue.sync {
            guard !isTornDown else { return }
            preAnimationImages = loadedImages
            isPreAnimationLoaded = !loadedImages.isEmpty
        }
        
        AppLogDebug("[PreAnim] loadPreAnimationImages - loaded \(loadedImages.count) frames, isPreAnimationLoaded: \(loadedImages.count > 0)")
        
        if let firstFrame = loadedImages.first {
            let defaultColorValue: CGFloat = 180.0
            
            let targetColor = interpolateColor(value: defaultColorValue)
            let colors = [NSColor.white, targetColor]
            let positions: [CGFloat] = [0.0, 0.1]
            
            if let gradient = GradientMapper.makeGradient(colors: colors, positions: positions),
               let strip = GradientMapper.makeStrip(from: gradient),
               let coloredFirst = GradientMapper.apply(to: firstFrame, using: strip) {
                
                AppLogDebug("[PreAnim] loadPreAnimationImages - displaying first frame (colored with default value)")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                imageView.image = coloredFirst
                CATransaction.commit()
                
                stateQueue.sync {
                    guard !isTornDown else { return }
                    cachedGradient = gradient
                    cachedStrip = strip
                    cachedColorValue = defaultColorValue
                }
            } else {
                AppLogDebug("[PreAnim] loadPreAnimationImages - coloring failed, displaying first frame (uncolored)")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                imageView.image = firstFrame
                CATransaction.commit()
            }
        }
    }
    
    private func preloadImages() {
        preloadWorkItem?.cancel()
        stateQueue.sync {
            isTornDown = false
            images = Array(repeating: Array(repeating: nil, count: cols + 1), count: rows + 1)
            coloredImages = Array(repeating: Array(repeating: nil, count: cols + 1), count: rows + 1)
            loadedCount = 0
        }
        
        if let centerImage = NSImage(named: "\(imageNamagePrefix)\(centerY)-\(centerX)") {
            stateQueue.sync {
                guard !isTornDown else { return }
                images[centerY][centerX] = centerImage
                loadedCount += 1
            }
            let hasPreAnimation = stateQueue.sync { isPreAnimationLoaded }
            AppLogDebug("[PreAnim] preloadImages - center image loaded, hasPreAnimation: \(hasPreAnimation), will show center: \(!hasPreAnimation)")
            if !hasPreAnimation {
                updateImage()
            }
        } else {
            AppLogWarn("Failed to load center image: \(centerY)-\(centerX)")
        }
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            for row in 1...self.rows {
                for col in 1...self.cols {
                    if self.preloadWorkItem?.isCancelled == true || self.isTornDownFlag() {
                        return
                    }
                    if row == self.centerY && col == self.centerX {
                        continue
                    }
                    
                    if let image = NSImage(named: "\(imageNamagePrefix)\(row)-\(col)") {
                        var shouldUpdate = false
                        self.stateQueue.sync {
                            guard !self.isTornDown,
                                  self.isValidIndex(row: row, col: col, in: self.images) else { return }
                            self.images[row][col] = image
                            self.loadedCount += 1
                            shouldUpdate = self.loadedCount == self.rows * self.cols
                        }
                        
                        if shouldUpdate {
                            DispatchQueue.main.async { [weak self] in
                                self?.updateImage()
                            }
                        }
                    } else {
                        AppLogError("Failed to load image: \(row)-\(col)")
                    }
                }
            }
        }
        preloadWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
    
    private func updateImage() {
        guard !isTornDownFlag() else { return }
        
        // Do not replace frames while the pre-animation sequence is playing.
        guard !isPlayingHintAnimation else {
            AppLogDebug("[PreAnim] updateImage - skipped, pre-animation is playing")
            return
        }
        
        // Skip redundant updates when the frame coordinates have not changed.
        guard currentX != lastDisplayedX || currentY != lastDisplayedY else {
            return
        }

        guard currentY >= 1, currentY <= rows,
              currentX >= 1, currentX <= cols else {
            return
        }

        lastDisplayedX = currentX
        lastDisplayedY = currentY

        // Prefer the colorized image when available.
        guard let displayImage = displayImageFor(row: currentY, col: currentX) else { return }
        
        // Disable implicit animations for frame-by-frame image swaps.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.image = displayImage
        CATransaction.commit()
    }
    
    override func mouseDown(with event: NSEvent) {
        // Stop the hint animation as soon as the user starts dragging.
        stopDragHintAnimation()
        
        isDragging = true
        startPoint = event.locationInWindow
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        handleDrag(at: event.locationInWindow)
    }
    
    override func mouseUp(with event: NSEvent) {
        isDragging = false
        returnToCenter()
    }
    
    private func handleDrag(at point: NSPoint) {
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        
        var needsUpdate = false
        
        if abs(dx) > sensitivity {
            if dx > 0 {
                currentX -= 1
            } else {
                currentX += 1
            }
            currentX = max(1, min(cols, currentX))
            startPoint.x = point.x
            needsUpdate = true
        }
        
        if abs(dy) > sensitivity {
            if dy < 0 {
                currentY -= 1
            } else {
                currentY += 1
            }
            currentY = max(1, min(rows, currentY))
            startPoint.y = point.y
            needsUpdate = true
        }
        
        if needsUpdate {
            updateImage()
        }
    }
    
    // MARK: - Return to Center Animation
    private func returnToCenter() {
        guard currentX != centerX || currentY != centerY else {
            return
        }
        
        isAnimating = true
        animationStartTime = CACurrentMediaTime()
        animationStartX = currentX
        animationStartY = currentY
        
        // Drive the return animation with a timer to keep updates predictable.
        Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self, self.isAnimating else {
                timer.invalidate()
                return
            }
            
            let elapsed = CACurrentMediaTime() - self.animationStartTime
            let duration: TimeInterval = 0.15
            var t = elapsed / duration
            
            if t >= 1 {
                t = 1
                self.isAnimating = false
                timer.invalidate()
            }
            
            // Ease out so the control settles smoothly at the center.
            let easeT = 1 - pow(1 - t, 3)
            
            self.currentX = Int(round(Double(self.animationStartX) + Double(self.centerX - self.animationStartX) * easeT))
            self.currentY = Int(round(Double(self.animationStartY) + Double(self.centerY - self.animationStartY) * easeT))
            
            self.updateImage()
        }
    }
    func colorSliderChanged(_ value: CGFloat) {
        guard !isTornDownFlag() else { return }
        stateQueue.sync {
            currentColorValue = value
        }
        
        // Only play the pre-animation on the first slider change after preload.
        let (shouldPlay, debugInfo) = stateQueue.sync { () -> (Bool, String) in
            let info = "isFirstSliderChange: \(isFirstSliderChange), isPreAnimationLoaded: \(isPreAnimationLoaded), hasPlayedPreAnimation: \(hasPlayedPreAnimation)"
            guard isFirstSliderChange, isPreAnimationLoaded, !hasPlayedPreAnimation else { return (false, info) }
            isFirstSliderChange = false
            hasPlayedPreAnimation = true
            return (true, info)
        }
        
        AppLogDebug("[PreAnim] colorSliderChanged - value: \(value), shouldPlayPreAnimation: \(shouldPlay), \(debugInfo)")
        
        if shouldPlay {
            // Colorize and play the pre-animation on the first slider change.
            colorAndPlayPreAnimation(colorValue: value)
        }
        
        // Update the center image first so feedback feels immediate.
        colorCenterImageFirst(colorValue: value)
        
        // Color the remaining frames asynchronously.
        colorAllImagesAsync(colorValue: value)
    }
    
    // MARK: - Pre-Animation Coloring & Playback
    
    /// Colorizes the pre-animation frames and starts playback.
    private func colorAndPlayPreAnimation(colorValue: CGFloat) {
        guard !isTornDownFlag() else {
            AppLogDebug("[PreAnim] colorAndPlayPreAnimation - isTornDown, skip")
            return
        }
        
        // Block other image updates while the pre-animation takes over.
        isPlayingHintAnimation = true
        
        AppLogDebug("[PreAnim] colorAndPlayPreAnimation - start coloring")
        
        updateGradientCache(colorValue: colorValue)
        
        guard let strip = stateQueue.sync(execute: { cachedStrip }) else {
            AppLogDebug("[PreAnim] colorAndPlayPreAnimation - no cached strip, skip")
            isPlayingHintAnimation = false
            return
        }
        
        let originalImages = stateQueue.sync { preAnimationImages }
        guard !originalImages.isEmpty else {
            AppLogDebug("[PreAnim] colorAndPlayPreAnimation - no original images, skip")
            isPlayingHintAnimation = false
            return
        }
        
        AppLogDebug("[PreAnim] colorAndPlayPreAnimation - coloring \(originalImages.count) frames")
        
        // Color and display the first frame immediately.
        var coloredImages: [NSImage] = []
        if let firstImage = originalImages.first {
            autoreleasepool {
                if let coloredFirst = GradientMapper.apply(to: firstImage, using: strip) {
                    coloredImages.append(coloredFirst)
                    AppLogDebug("[PreAnim] colorAndPlayPreAnimation - displaying first colored frame")
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    imageView.image = coloredFirst
                    CATransaction.commit()
                }
            }
        }
        
        // Color the remaining frames.
        for i in 1..<originalImages.count {
            autoreleasepool {
                if let coloredImage = GradientMapper.apply(to: originalImages[i], using: strip) {
                    coloredImages.append(coloredImage)
                }
            }
        }
        
        AppLogDebug("[PreAnim] colorAndPlayPreAnimation - colored \(coloredImages.count) frames, starting playback")
        
        stateQueue.sync {
            guard !isTornDown else { return }
            coloredPreAnimationImages = coloredImages
        }
        
        playPreAnimationSequence()
    }
    
    /// Plays the pre-animation frame sequence.
    private func playPreAnimationSequence() {
        guard !isTornDownFlag() else {
            AppLogDebug("[PreAnim] playPreAnimationSequence - isTornDown, skip")
            return
        }
        
        let coloredImages = stateQueue.sync { coloredPreAnimationImages }
        guard !coloredImages.isEmpty else {
            AppLogDebug("[PreAnim] playPreAnimationSequence - no colored images, skip")
            return
        }
        
        isPlayingHintAnimation = true
        
        let frameCount = coloredImages.count
        let totalDuration: TimeInterval = 1.0  // 1000ms
        let frameInterval = totalDuration / Double(frameCount)
        
        AppLogDebug("[PreAnim] playPreAnimationSequence - starting playback, \(frameCount) frames, interval: \(frameInterval)s")
        
        var currentFrame = 0
        let startTime = CACurrentMediaTime()
        
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self, self.isPlayingHintAnimation, !self.isDragging else {
                timer.invalidate()
                self?.finishPreAnimation()
                return
            }
            
            let elapsed = CACurrentMediaTime() - startTime
            let targetFrame = min(Int(elapsed / frameInterval), frameCount - 1)
            
            // Only swap the image when the target frame changes.
            if targetFrame != currentFrame || currentFrame == 0 {
                currentFrame = targetFrame
                
                let images = self.stateQueue.sync { self.coloredPreAnimationImages }
                guard currentFrame < images.count else {
                    timer.invalidate()
                    self.finishPreAnimation()
                    return
                }
                
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.imageView.image = images[currentFrame]
                CATransaction.commit()
            }
            
            if elapsed >= totalDuration {
                timer.invalidate()
                self.finishPreAnimation()
            }
        }
        
        hintAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    
    /// Finishes the pre-animation and releases its cached images.
    private func finishPreAnimation() {
        AppLogDebug("[PreAnim] finishPreAnimation - animation completed, releasing resources")
        
        isPlayingHintAnimation = false
        hintAnimationTimer = nil
        
        updateImage()
        
        stateQueue.sync {
            preAnimationImages.removeAll()
            coloredPreAnimationImages.removeAll()
            isPreAnimationLoaded = false
        }
        
        AppLogDebug("[PreAnim] finishPreAnimation - done, showing center image")
    }
    
    
    func colorCenterImageFirst(colorValue: CGFloat) {
        guard !isTornDownFlag() else { return }
        guard let originalImage = image(atRow: centerY, col: centerX) else { return }
        
        updateGradientCache(colorValue: colorValue)
        
        guard let strip = stateQueue.sync(execute: { cachedStrip }) else { return }
        autoreleasepool {
            if let coloredImage = GradientMapper.apply(to: originalImage, using: strip) {
                setColoredImage(coloredImage, row: centerY, col: centerX)
                
                // Avoid flicker while the pre-animation is still playing.
                guard !isPlayingHintAnimation else {
                    AppLogDebug("[PreAnim] colorCenterImageFirst - skipped, pre-animation is playing")
                    return
                }
                
                // Refresh immediately when the center image is currently visible.
                if currentX == centerX && currentY == centerY {
                    AppLogDebug("[PreAnim] colorCenterImageFirst - displaying colored center image")
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    imageView.image = coloredImage
                    CATransaction.commit()
                }
            }
        }
        
    }
    
    private func colorAllImagesAsync(colorValue: CGFloat) {
        let shouldStart = stateQueue.sync { () -> Bool in
            guard !isTornDown, !isColoringInProgress else { return false }
            isColoringInProgress = true
            return true
        }
        guard shouldStart else { return }
        
        colorWorkItem?.cancel()
        let capturedColorValue = colorValue
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            guard let strip = self.stateQueue.sync(execute: { self.cachedStrip }) else {
                DispatchQueue.main.async {
                    self.stateQueue.sync {
                        self.isColoringInProgress = false
                    }
                }
                return
            }
            
            // Prioritize frames closest to the center.
            let priorities = self.getPriorityOrder()
            
            for (row, col) in priorities {
                if self.colorWorkItem?.isCancelled == true || self.isTornDownFlag() {
                    break
                }
                // Abort if a new slider value superseded this work item.
                let isColorUnchanged = self.stateQueue.sync { self.currentColorValue == capturedColorValue }
                guard isColorUnchanged else {
                    DispatchQueue.main.async {
                        self.stateQueue.sync {
                            self.isColoringInProgress = false
                        }
                    }
                    return
                }

                guard let originalImage = self.image(atRow: row, col: col) else { continue }

                if let coloredImage = GradientMapper.apply(to: originalImage, using: strip) {
                    self.setColoredImage(coloredImage, row: row, col: col)
                    
                    // Refresh immediately when the current frame changes underneath the viewer.
                    if row == self.currentY && col == self.currentX {
                        DispatchQueue.main.async {
                            self.updateImage()
                        }
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.stateQueue.sync {
                    self.isColoringInProgress = false
                }
            }
        }
        colorWorkItem = workItem
        colorQueue.async(execute: workItem)
    }

    private func isValidIndex(row: Int, col: Int, in matrix: [[NSImage?]]) -> Bool {
        return row >= 0 && row < matrix.count && col >= 0 && col < matrix[row].count
    }

    private func image(atRow row: Int, col: Int) -> NSImage? {
        return stateQueue.sync {
            guard isValidIndex(row: row, col: col, in: images) else { return nil }
            return images[row][col]
        }
    }

    private func coloredImage(atRow row: Int, col: Int) -> NSImage? {
        return stateQueue.sync {
            guard isValidIndex(row: row, col: col, in: coloredImages) else { return nil }
            return coloredImages[row][col]
        }
    }

    private func setColoredImage(_ image: NSImage?, row: Int, col: Int) {
        stateQueue.sync {
            guard !isTornDown, isValidIndex(row: row, col: col, in: coloredImages) else { return }
            coloredImages[row][col] = image
        }
    }
    
    private func updateGradientCache(colorValue: CGFloat) {
        // Reuse the cached gradient when the slider value is unchanged.
        let needsUpdate = stateQueue.sync { !isTornDown && abs(colorValue - cachedColorValue) > 0.001 }
        guard needsUpdate else { return }
        
        let targetColor = interpolateColor(value: colorValue)
        let color0 = NSColor.white
        let colors = [color0, targetColor]
        let positions: [CGFloat] = [0.0, 0.1]
        
        guard let gradient = GradientMapper.makeGradient(colors: colors, positions: positions) else {
            return
        }
        
        guard let strip = GradientMapper.makeStrip(from: gradient) else {
            return
        }
        
        stateQueue.sync {
            guard !isTornDown else { return }
            cachedGradient = gradient
            cachedStrip = strip
            cachedColorValue = colorValue
        }
    }
    
    private func getPriorityOrder() -> [(Int, Int)] {
        var result: [(Int, Int)] = []
//        var visited = Set<String>()
        
        func distance(_ row: Int, _ col: Int) -> Int {
            return abs(row - centerY) + abs(col - centerX)
        }
        
        for row in 1...rows {
            for col in 1...cols {
                result.append((row, col))
            }
        }
        
        // Process frames nearest to the center first.
        result.sort { distance($0.0, $0.1) < distance($1.0, $1.1) }
        
        return result
    }
    
    private func interpolateColor(value: CGFloat) -> NSColor {
        let hue = value / 360.0
        let saturation: CGFloat = 0.85
        let brightness: CGFloat = 0.75
        return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1.0)
    }

    private func displayImageFor(row: Int, col: Int) -> NSImage? {
        return stateQueue.sync {
            guard !isTornDown,
                  isValidIndex(row: row, col: col, in: coloredImages),
                  isValidIndex(row: row, col: col, in: images) else { return nil }
            return coloredImages[row][col] ?? images[row][col]
        }
    }

    private func isTornDownFlag() -> Bool {
        return stateQueue.sync { isTornDown }
    }
    
    /// Stops the hint animation and snaps back to the center frame.
    func stopDragHintAnimation() {
        guard isPlayingHintAnimation else { return }
        
        hintAnimationTimer?.invalidate()
        hintAnimationTimer = nil
        isPlayingHintAnimation = false
        
        stateQueue.sync {
            if !preAnimationImages.isEmpty || !coloredPreAnimationImages.isEmpty {
                preAnimationImages.removeAll()
                coloredPreAnimationImages.removeAll()
                isPreAnimationLoaded = false
            }
        }
        
        currentX = centerX
        currentY = centerY
        updateImage()
    }
}
