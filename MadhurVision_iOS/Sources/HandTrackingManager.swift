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

    static let noHand = HandTrackingInput(
        indexTipPosition: .zero,
        isPinching: false,
        scrollDelta: 0,
        isGrabbing: false,
        grabPosition: .zero
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
              thumbTip.confidence > 0.5 else { return }

        let indexPos = CGPoint(x: indexTip.location.x,
                               y: 1.0 - indexTip.location.y)
        let thumbPos = CGPoint(x: thumbTip.location.x,
                               y: 1.0 - thumbTip.location.y)

        // Pinch detection: Index and thumb close, and middle/ring explicitly straight
        let middleStraight = middleTip.location.y > middleMCP.location.y
        let ringStraight = ringTip.location.y > ringMCP.location.y
        let pinchDist = hypot(indexPos.x - thumbPos.x, indexPos.y - thumbPos.y)
        let pinchDetected = pinchDist < 0.05 && middleStraight && ringStraight
        
        // Fist / Grab detection (all fingers curled)
        let isFist = (indexTip.location.y < indexMCP.location.y) &&
                     (middleTip.location.y < middleMCP.location.y) &&
                     (ringTip.location.y < ringMCP.location.y)

        let wristPos = CGPoint(x: wrist.location.x, y: 1.0 - wrist.location.y)

        // Scroll detection (only when NOT grabbing)
        let palmY = 1.0 - wrist.location.y
        var scrollD: CGFloat = 0
        if !isFist, let prevY = previousPalmY {
            scrollD = palmY - prevY
        }
        previousPalmY = isFist ? nil : palmY

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isTracking else { return }
            self.indexTipPosition = indexPos
            self.scrollDelta = scrollD
            self.isGrabbing = isFist
            self.grabPosition = wristPos

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
                        grabPosition: self.grabPosition
                    )
                }
                
                // Keep the cooldown longer so we don't rapid-fire clicks
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.pinchCooldown = false
                }
            }

            self.latestInput = HandTrackingInput(
                indexTipPosition: indexPos,
                isPinching: self.isPinching,
                scrollDelta: scrollD,
                isGrabbing: isFist,
                grabPosition: wristPos
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
