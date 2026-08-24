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
    private var openPalmStartedAt: Date?
    private var isRunning = false

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

        let indexPos = CGPoint(x: indexTip.location.x,
                               y: 1.0 - indexTip.location.y)
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
        let middleExtended = isExtended(middleTip, middleMCP)
        let ringExtended = isExtended(ringTip, ringMCP)
        let middleCurled = isCurled(middleTip, middleMCP)
        let ringCurled = isCurled(ringTip, ringMCP)
        let littleCurled: Bool
        let thumbFolded: Bool
        let littleExtended: Bool
        let thumbExtended: Bool
        if let littleTip, let littleMCP {
            littleCurled = isCurled(littleTip, littleMCP)
            littleExtended = isExtended(littleTip, littleMCP)
            // Normalize the thumb position by the palm width so a thumbs-up
            // or open thumb cannot count as a closed fist.
            let palmWidth = max(distance(indexMCP, littleMCP), 0.01)
            thumbFolded = distance(thumbTip, indexMCP) <= palmWidth * 1.5
            thumbExtended = distance(thumbTip, wrist) > palmWidth * 1.2
        } else {
            littleCurled = false
            littleExtended = false
            thumbFolded = false
            thumbExtended = false
        }

        // A window grab needs a real closed fist. A partly open hand, an
        // incomplete pinch, or a sideways point cannot satisfy this test.
        let isFist = isCurled(indexTip, indexMCP) && middleCurled && ringCurled && littleCurled && thumbFolded

        // Index extension is the only requirement for pointing. Do not gate
        // it on the other fingers: their confidence drops first when a hand
        // is sideways, which previously made the cursor disappear.
        let isPointing = indexExtended && !isFist

        // An open palm is deliberately unused by the pointer and grab modes,
        // making it a reliable one-hand reset gesture.
        let isOpenPalm = indexExtended && middleExtended && ringExtended && littleExtended && thumbExtended

        // Pinch detection is evaluated only while pointing. Leaving a gap
        // between thumb and index therefore stays in pointer mode.
        let pinchDist = hypot(indexPos.x - thumbPos.x, indexPos.y - thumbPos.y)
        let pinchDetected = isPointing && pinchDist < 0.05

        let wristPos = CGPoint(x: wrist.location.x, y: 1.0 - wrist.location.y)
        let cursorPosition = isPointing ? indexPos : .zero
        let palmSpan = distance(indexMCP, wrist)

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

            if isOpenPalm {
                if self.openPalmStartedAt == nil {
                    self.openPalmStartedAt = Date()
                }
            } else {
                self.openPalmStartedAt = nil
            }

            // Hold an open palm for one second to reset. A quick open hand
            // remains available for ordinary index-finger pointing.
            let openPalmHeldLongEnough = self.openPalmStartedAt.map {
                Date().timeIntervalSince($0) >= 1.0
            } ?? false
            let resetRequested = openPalmHeldLongEnough && !self.resetCooldown
            if resetRequested {
                self.resetCooldown = true
                self.openPalmStartedAt = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.resetCooldown = false
                }
            }

            if pinchDetected && !self.pinchCooldown && !isFist {
                self.isPinching = true
                self.pinchCooldown = true
                
                // Pulse isPinching back to false almost immediately so we only click once
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.isPinching = false
                    self.latestInput = HandTrackingInput(
                        indexTipPosition: self.indexTipPosition,
                        isPinching: false,
                        scrollDelta: 0,
                        isGrabbing: self.isGrabbing,
                        grabPosition: self.grabPosition,
                        palmSpan: palmSpan,
                        resetRequested: false
                    )
                }
                
                // Keep the cooldown longer so we don't rapid-fire clicks
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
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
