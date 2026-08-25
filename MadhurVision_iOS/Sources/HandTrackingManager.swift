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
    private var pinchReleased = true
    private var resetCooldown = false
    private var openPalmStartedAt: Date?
    private var lastHandSeenAt: Date? = nil
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

    private var didLogFirstVision = false
    private var didLogFirstHandDetected = false

    func start() {
        stateLock.lock()
        isRunning = true
        stateLock.unlock()
        AppLogger.shared.log("[HandTrackingManager] Started tracking")
    }

    func stop() {
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
        AppLogger.shared.log("[HandTrackingManager] Stopped tracking")

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

        if !didLogFirstVision {
            didLogFirstVision = true
            AppLogger.shared.log("[HandTrackingManager] First Vision frame running")
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([handPoseRequest])
        } catch {
            AppLogger.shared.log("[HandTrackingManager] Vision error: \(error)")
            return
        }

        if let observation = handPoseRequest.results?.first {
            lastHandSeenAt = Date()
            if !didLogFirstHandDetected {
                didLogFirstHandDetected = true
                AppLogger.shared.log("[HandTrackingManager] First hand successfully detected by Vision!")
            }
            processHandObservation(observation)
        } else {
            // Temporal Grace Period: hold cursor for up to 350ms on momentary camera drops
            let elapsed = lastHandSeenAt.map { Date().timeIntervalSince($0) } ?? 1.0
            if elapsed > 0.35 {
                DispatchQueue.main.async {
                    guard self.isTracking else { return }
                    self.indexTipPosition = .zero
                    self.isGrabbing = false
                    self.latestInput = .noHand
                }
                previousPalmY = nil
            }
        }
    }

    // MARK: - Hand Landmark Processing

    private func processHandObservation(_ observation: VNHumanHandPoseObservation) {
        guard let indexTip = try? observation.recognizedPoint(.indexTip),
              let indexMCP = try? observation.recognizedPoint(.indexMCP),
              let wrist    = try? observation.recognizedPoint(.wrist),
              indexTip.confidence > 0.20,
              wrist.confidence > 0.15 else { return }

        let indexPIP  = try? observation.recognizedPoint(.indexPIP)
        let middleTip = try? observation.recognizedPoint(.middleTip)
        let middleMCP = try? observation.recognizedPoint(.middleMCP)
        let ringTip   = try? observation.recognizedPoint(.ringTip)
        let ringMCP   = try? observation.recognizedPoint(.ringMCP)
        let thumbTip  = try? observation.recognizedPoint(.thumbTip)
        let littleTip = try? observation.recognizedPoint(.littleTip)
        let littleMCP = try? observation.recognizedPoint(.littleMCP)

        let indexPos = CGPoint(x: indexTip.location.x, y: 1.0 - indexTip.location.y)
        let thumbPos = thumbTip.map { CGPoint(x: $0.location.x, y: 1.0 - $0.location.y) } ?? .zero
        let middlePos = middleTip.map { CGPoint(x: $0.location.x, y: 1.0 - $0.location.y) } ?? .zero

        func distance(_ first: VNRecognizedPoint?, _ second: VNRecognizedPoint?) -> CGFloat {
            guard let first = first, let second = second else { return 999.0 }
            return hypot(first.location.x - second.location.x, first.location.y - second.location.y)
        }

        // Finger extension is measured relative to the wrist instead of using
        // only vertical screen coordinates.
        func isExtended(_ tip: VNRecognizedPoint?, _ knuckle: VNRecognizedPoint?) -> Bool {
            guard let tip = tip, let knuckle = knuckle, tip.confidence > 0.20, knuckle.confidence > 0.15 else { return false }
            return distance(tip, wrist) > distance(knuckle, wrist) * 1.15
        }

        func isCurled(_ tip: VNRecognizedPoint?, _ knuckle: VNRecognizedPoint?) -> Bool {
            guard let tip = tip, let knuckle = knuckle, tip.confidence > 0.20, knuckle.confidence > 0.15 else { return false }
            return distance(tip, wrist) <= distance(knuckle, wrist) * 1.15
        }

        let indexExtended  = isExtended(indexTip, indexMCP)
        let middleExtended = isExtended(middleTip, middleMCP)
        let ringExtended   = isExtended(ringTip, ringMCP)
        let middleCurled   = isCurled(middleTip, middleMCP)
        let ringCurled     = isCurled(ringTip, ringMCP)
        let littleCurled: Bool
        let thumbFolded: Bool
        let thumbExtended: Bool

        if let littleTip = littleTip, let littleMCP = littleMCP {
            littleCurled = isCurled(littleTip, littleMCP)
        } else {
            littleCurled = false
        }

        if let thumbTip = thumbTip {
            let palmWidth = max(distance(indexMCP, littleMCP ?? indexMCP), 0.01)
            thumbFolded = distance(thumbTip, indexMCP) <= palmWidth * 1.5
            thumbExtended = distance(thumbTip, wrist) > palmWidth * 1.2
        } else {
            thumbFolded = false
            thumbExtended = false
        }

        // GESTURE 1: Grab (Closed Fist — all 4 curled + thumb folded)
        let isFist = isCurled(indexTip, indexMCP) && middleCurled && ringCurled && littleCurled && thumbFolded

        // GESTURE 2: Reset (Open Palm ✋ — all fingers extended flat facing camera)
        let isOpenPalm = indexExtended && middleExtended && ringExtended

        // GESTURE 3: Two-Finger Scroll ✌️ (Index + Middle extended)
        let isTwoFingerScroll = indexExtended && middleExtended && !isFist && !isOpenPalm

        // PINCH / CLICK GESTURE (Index Tip + Thumb Tip touch distance)
        let thumbIndexDist = hypot(thumbPos.x - indexPos.x, thumbPos.y - indexPos.y)
        let isPinchingFingers = (thumbTip != nil) && (thumbIndexDist < 0.045)
        
        // Hysteresis: Must release fingers to > 0.060 to unlock next click
        if !isPinchingFingers && thumbIndexDist > 0.060 {
            pinchReleased = true
        }

        // GESTURE 4: Single-Finger Point 👆 (Active whenever not fist, not scroll, not open palm)
        let isPointing = (!isTwoFingerScroll && !isFist && !isOpenPalm) || isPinchingFingers || pinchCooldown
        
        let clickDetected = isPointing && isPinchingFingers && pinchReleased && !pinchCooldown && !isFist

        let wristPos = CGPoint(x: wrist.location.x, y: 1.0 - wrist.location.y)
        let indexMCPPos = CGPoint(x: indexMCP.location.x, y: 1.0 - indexMCP.location.y)
        let palmSpan = distance(indexMCP, wrist)

        // Biomechanical 3D Bone Ray Projection (Index Knuckle -> Index Tip)
        let dirX = indexPos.x - indexMCPPos.x
        let dirY = indexPos.y - indexMCPPos.y
        let boneLength = hypot(dirX, dirY)
        
        let extendedPointing: CGPoint
        if boneLength > 0.02 {
            let normDirX = dirX / boneLength
            let normDirY = dirY / boneLength
            // Project ray slightly forward along finger bone axis
            extendedPointing = CGPoint(
                x: max(0.0, min(1.0, indexPos.x + normDirX * 0.08)),
                y: max(0.0, min(1.0, indexPos.y + normDirY * 0.08))
            )
        } else {
            extendedPointing = indexPos
        }
        
        // Freeze cursor on click so it never drifts
        let cursorPosition: CGPoint
        if pinchCooldown {
            cursorPosition = lastGoodCursorPosition
        } else if isPointing {
            lastGoodCursorPosition = indexPos
            cursorPosition = indexPos
        } else {
            cursorPosition = .zero
        }

        // Scroll Tracking (Active ONLY in Two-Finger Scroll Mode)
        let palmY = 1.0 - wrist.location.y
        var scrollD: CGFloat = 0
        if isTwoFingerScroll, let prevY = previousPalmY {
            let rawDelta = palmY - prevY
            // Deadband to ignore tiny hand tremors, amplify deliberate motion
            if abs(rawDelta) > 0.003 {
                scrollD = rawDelta * 1.6
            }
        }
        previousPalmY = isTwoFingerScroll ? palmY : nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isTracking else { return }
            self.indexTipPosition = cursorPosition
            self.scrollDelta = scrollD
            self.isGrabbing = isFist
            self.grabPosition = wristPos

            // RESET COMMAND: Open Palm held for 2.0 seconds
            if isOpenPalm {
                if self.openPalmStartedAt == nil {
                    self.openPalmStartedAt = Date()
                }
            } else {
                self.openPalmStartedAt = nil
            }

            let openPalmHeldLongEnough = self.openPalmStartedAt.map {
                Date().timeIntervalSince($0) >= 2.0
            } ?? false
            let resetRequested = openPalmHeldLongEnough && !self.resetCooldown
            if resetRequested {
                self.resetCooldown = true
                self.openPalmStartedAt = nil
                AppLogger.shared.log("[HandTrackingManager] Open Palm Reset triggered (2.0s hold)!")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.resetCooldown = false
                }
            }

            // CLICK TRIGGER: fire click at the frozen cursor position
            if clickDetected && !self.pinchCooldown && !isFist {
                self.isPinching = true
                self.pinchCooldown = true
                self.pinchReleased = false
                
                // Pulse isPinching back to false almost immediately for a crisp click
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
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
