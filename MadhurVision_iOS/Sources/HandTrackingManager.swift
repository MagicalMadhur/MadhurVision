import AVFoundation
import Vision
import Combine
import CoreImage

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

    private let processingQueue = DispatchQueue(label: "HandTrackingQueue", qos: .userInteractive)

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

    private override init() {
        super.init()
    }

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
        previousPalmY = nil
    }

    /// Called by PassthroughManager with each camera frame
    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRunning, !isProcessingFrame else { return }
        isProcessingFrame = true

        // Capture immutable CGImage synchronously to avoid CVPixelBuffer mutation crashes
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            self.isProcessingFrame = false
            return
        }

        processingQueue.async { [weak self] in
            defer { self?.isProcessingFrame = false }
            self?.runVision(on: cgImage)
        }
    }

    private func runVision(on image: CGImage) {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([handPoseRequest])
        } catch {
            return
        }

        guard let observation = handPoseRequest.results?.first else {
            DispatchQueue.main.async {
                self.indexTipPosition = .zero
                self.isGrabbing = false
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
            guard let self = self else { return }
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
                }
                
                // Keep the cooldown longer so we don't rapid-fire clicks
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.pinchCooldown = false
                }
            }
        }
    }
}
