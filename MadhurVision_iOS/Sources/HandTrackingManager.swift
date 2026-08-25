import AVFoundation
import Vision
import Combine
import CoreImage

/// An atomic result from one Vision pass. Consumers should subscribe to this
/// instead of combining the individual @Published properties, which can expose
/// partially updated gesture state.
struct HandTrackingInput {
    let indexTipPosition: CGPoint
    let isPinching: Bool
    let scrollDelta: CGFloat
    let isGrabbing: Bool
    let grabPosition: CGPoint
    /// Apparent palm size used as a single-camera proxy for moving closer/farther.
    let palmSpan: CGFloat
    /// A one-shot open-palm command that restores the VR monitor.
    let resetRequested: Bool

    static let noHand = HandTrackingInput(
        indexTipPosition: .zero,
        isPinching: false,
        scrollDelta: 0,
        isGrabbing: false,
        grabPosition: .zero,
        palmSpan: 0,
        resetRequested: false
    )
}

/// Detects hand pose from camera frames and publishes
/// normalized finger positions and gesture states.
/// NOTE: Does NOT run its own camera session.
/// Frames are fed by PassthroughManager.processFrame() to avoid dual-session conflicts.
class HandTrackingManager: NSObject {
    static let shared = HandTrackingManager()

    // Published values
    @Published var indexTipPosition: CGPoint = .zero
    @Published var isPinching: Bool = false
    @Published var scrollDelta: CGFloat = 0.0
    @Published var isGrabbing: Bool = false
    @Published var grabPosition: CGPoint = .zero
    @Published private(set) var latestInput: HandTrackingInput = .noHand

    // Vision request
    private lazy var handPoseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()

    // Tracking state
    private var previousPalmY: CGFloat? = nil
    private var pinchCooldown = false
    private var resetCooldown = false
    private var thumbsUpStartedAt: Date?
    private var isRunning = false
    /// Last good cursor position before a pinch started. Used to freeze the
    /// click location so it lands exactly where the user was pointing.
    private var lastGoodCursorPosition: CGPoint = .zero

    // Frame processing mutex
    private var isProcessingFrame = false
    private let stateLock = NSLock()

    private override init() {
        super.init()
    }

    func start() {
        stateLock.lock()
        isRunning = true
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        isRunning = false
        stateLock.unlock()

        // previousPalmY belongs to the serial Vision queue.
        processingQueue.async { [weak self] in
            self?.previousPalmY = nil
        }
    }

    private let processingQueue = DispatchQueue(label: "HandTrackingQueue", qos: .userInteractive)

    /// Called by PassthroughManager with each camera frame
    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        guard isRunning, !isProcessingFrame else {
            stateLock.unlock()
            return
        }
        isProcessingFrame = true
        stateLock.unlock()
        
        // Deep copy the pixel buffer synchronously before returning, so the camera hardware can 
        // immediately recycle the original buffer. This prevents EX_BAD_ACCESS (memory corruption)
        // AND prevents OS Watchdog timeouts (which happen if we block the camera queue too long).
        guard let copiedBuffer = pixelBuffer.deepCopy() else {
            finishProcessingFrame()
            return
        }
        
        processingQueue.async { [weak self] in
            autoreleasepool {
                defer { self?.finishProcessingFrame() }
                self?.runVision(on: copiedBuffer)
            }
        }
    }

    private func finishProcessingFrame() {
        stateLock.lock()
        isProcessingFrame = false
        stateLock.unlock()
    }

    private var isTracking: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    private func runVision(on pixelBuffer: CVPixelBuffer) {
        guard isTracking else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([handPoseRequest])
        } catch {
            return
        }

        guard let observation = handPoseRequest.results?.first else {
            DispatchQueue.main.async {
                guard self.isTracking else { return }
                self.indexTipPosition = .zero
                self.isGrabbing = false
                self.latestInput = .noHand
            }
            previousPalmY = nil
            return
        }

        processHandObservation(observation)
    }

    // MARK: - Hand Landmark Processing

    private func processHandObservation(_ observation: VNHumanHandPoseObservation) {
        guard let indexTip  = try? observation.recognizedPoint(.indexTip),
              let indexPIP  = try? observation.recognizedPoint(.indexPIP),
              let indexMCP  = try? observation.recognizedPoint(.indexMCP),
              let middleTip = try? observation.recognizedPoint(.middleTip),
              let middleMCP = try? observation.recognizedPoint(.middleMCP),
              let ringTip   = try? observation.recognizedPoint(.ringTip),
              let ringMCP   = try? observation.recognizedPoint(.ringMCP),
              let thumbTip  = try? observation.recognizedPoint(.thumbTip),
              let wrist     = try? observation.recognizedPoint(.wrist),
              indexTip.confidence > 0.5,
              thumbTip.confidence > 0.5,
              wrist.confidence > 0.5 else { return }

        // The little finger completes the fist test. It is optional only so a
        // temporarily occluded little finger can never turn a partial gesture
        // into a grab.
        let littleTip = try? observation.recognizedPoint(.littleTip)
        let littleMCP = try? observation.recognizedPoint(.littleMCP)

        // Use a blend of index tip and PIP (middle knuckle) for cursor position.
        // The PIP barely moves during a pinch, making the cursor far more stable.
        // 60% PIP + 40% tip gives a good balance of stability and responsiveness.
        let stableX = indexPIP.location.x * 0.6 + indexTip.location.x * 0.4
        let stableY = indexPIP.location.y * 0.6 + indexTip.location.y * 0.4
        let indexPos = CGPoint(x: stableX, y: 1.0 - stableY)
        let thumbPos = CGPoint(x: thumbTip.location.x,
                               y: 1.0 - thumbTip.location.y)

        func distance(_ first: VNRecognizedPoint, _ second: VNRecognizedPoint) -> CGFloat {
            hypot(first.location.x - second.location.x, first.location.y - second.location.y)
        }

        // Finger extension is measured relative to the wrist instead of using
        // only vertical screen coordinates. The former still works when the
        // user points sideways, which was the source of false fist detections.
        func isExtended(_ tip: VNRecognizedPoint, _ knuckle: VNRecognizedPoint) -> Bool {
            guard tip.confidence > 0.5, knuckle.confidence > 0.3 else { return false }
            return distance(tip, wrist) > distance(knuckle, wrist) * 1.25
        }

        func isCurled(_ tip: VNRecognizedPoint, _ knuckle: VNRecognizedPoint) -> Bool {
            guard tip.confidence > 0.5, knuckle.confidence > 0.3 else { return false }
            return distance(tip, wrist) <= distance(knuckle, wrist) * 1.15
        }

        let indexExtended = isExtended(indexTip, indexMCP)
        let middleCurled = isCurled(middleTip, middleMCP)
        let ringCurled = isCurled(ringTip, ringMCP)
        let littleCurled: Bool
        let thumbFolded: Bool
        let thumbExtended: Bool
        if let littleTip, let littleMCP {
            littleCurled = isCurled(littleTip, littleMCP)
            // Normalize the thumb position by the palm width so a thumbs-up
            // or open thumb cannot count as a closed fist.
            let palmWidth = max(distance(indexMCP, littleMCP), 0.01)
            thumbFolded = distance(thumbTip, indexMCP) <= palmWidth * 1.5
            thumbExtended = distance(thumbTip, wrist) > palmWidth * 1.2
        } else {
            littleCurled = false
            thumbFolded = false
            thumbExtended = false
        }

        // A window grab needs a real closed fist. A partly open hand, an
        // incomplete pinch, or a sideways point cannot satisfy this test.
        let isFist = isCurled(indexTip, indexMCP) && middleCurled && ringCurled && littleCurled && thumbFolded

        // Index extension is the only requirement for pointing. Do not gate
        // it on the other fingers: their confidence drops first when a hand
        // is sideways, which previously made the cursor disappear.
        // During pinch cooldown, keep isPointing true so the cursor stays visible.
        let isPointing = (indexExtended && !isFist) || pinchCooldown

        // RESET GESTURE: Thumbs Up 👍 (thumb extended + all 4 fingers curled).
        // This is a unique gesture that cannot overlap with pointing (index
        // extended) or grabbing (thumb folded into fist).
        let isThumbsUp = thumbExtended && isCurled(indexTip, indexMCP) && middleCurled && ringCurled && littleCurled

        // Pinch detection: use raw thumb-to-index-tip distance.
        // The pinch is detected while pointing, before the finger fully bends.
        let pinchDist = hypot(thumbPos.x - indexPos.x, thumbPos.y - indexPos.y)
        let pinchDetected = isPointing && !pinchCooldown && pinchDist < 0.06

        let wristPos = CGPoint(x: wrist.location.x, y: 1.0 - wrist.location.y)
        let palmSpan = distance(indexMCP, wrist)

        // When pointing normally, continuously update lastGoodCursorPosition.
        // When a pinch is detected, freeze at this position so the click
        // lands exactly where the user was aiming.
        let cursorPosition: CGPoint
        if pinchCooldown {
            // During pinch cooldown, keep cursor frozen at last good position
            cursorPosition = lastGoodCursorPosition
        } else if isPointing {
            lastGoodCursorPosition = indexPos
            cursorPosition = indexPos
        } else {
            cursorPosition = .zero
        }

        // Scroll detection (only when NOT grabbing)
        let palmY = 1.0 - wrist.location.y
        var scrollD: CGFloat = 0
        if !isFist, let prevY = previousPalmY {
            scrollD = palmY - prevY
        }
        previousPalmY = isFist ? nil : palmY

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isTracking else { return }
            self.indexTipPosition = cursorPosition
            self.scrollDelta = scrollD
            self.isGrabbing = isFist
            self.grabPosition = wristPos

            // RESET: Thumbs Up held for 1.5 seconds
            if isThumbsUp {
                if self.thumbsUpStartedAt == nil {
                    self.thumbsUpStartedAt = Date()
                }
            } else {
                self.thumbsUpStartedAt = nil
            }

            let thumbsUpHeldLongEnough = self.thumbsUpStartedAt.map {
                Date().timeIntervalSince($0) >= 1.5
            } ?? false
            let resetRequested = thumbsUpHeldLongEnough && !self.resetCooldown
            if resetRequested {
                self.resetCooldown = true
                self.thumbsUpStartedAt = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.resetCooldown = false
                }
            }

            // PINCH CLICK: fire click at the frozen cursor position
            if pinchDetected && !self.pinchCooldown && !isFist {
                self.isPinching = true
                self.pinchCooldown = true
                
                // Pulse isPinching back to false almost immediately so we only click once
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.isPinching = false
                    self.latestInput = HandTrackingInput(
                        indexTipPosition: cursorPosition,
                        isPinching: false,
                        scrollDelta: 0,
                        isGrabbing: self.isGrabbing,
                        grabPosition: self.grabPosition,
                        palmSpan: palmSpan,
                        resetRequested: false
                    )
                }
                
                // Keep the cooldown longer so we don't rapid-fire clicks.
                // During this time cursor stays frozen and visible.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.pinchCooldown = false
                }
            }

            self.latestInput = HandTrackingInput(
                indexTipPosition: cursorPosition,
                isPinching: self.isPinching,
                scrollDelta: scrollD,
                isGrabbing: isFist,
                grabPosition: wristPos,
                palmSpan: palmSpan,
                resetRequested: resetRequested
            )
        }
    }
}

extension CVPixelBuffer {
    func deepCopy() -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)
        let format = CVPixelBufferGetPixelFormatType(self)
        
        var copy: CVPixelBuffer?
        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            // Enables IOSurface-backed storage so Vision can choose a hardware
            // path when supported; Vision still selects its own execution unit.
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, options as CFDictionary, &copy)
        guard status == kCVReturnSuccess, let dest = copy else { return nil }
        
        CVPixelBufferLockBaseAddress(self, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        
        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(self, .readOnly)
        }
        
        guard let srcBase = CVPixelBufferGetBaseAddress(self),
              let destBase = CVPixelBufferGetBaseAddress(dest) else { return nil }
        
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(self)
        let destBytesPerRow = CVPixelBufferGetBytesPerRow(dest)
        
        if srcBytesPerRow == destBytesPerRow {
            memcpy(destBase, srcBase, height * srcBytesPerRow)
        } else {
            for y in 0..<height {
                memcpy(destBase.advanced(by: y * destBytesPerRow), srcBase.advanced(by: y * srcBytesPerRow), min(srcBytesPerRow, destBytesPerRow))
            }
        }
        
        return dest
    }
}
