import AVFoundation
import Vision
import Combine

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

    private override init() {
        super.init()
    }

    func start() {
        isRunning = true
        // No camera session — PassthroughManager feeds us frames
    }

    func stop() {
        isRunning = false
        previousPalmY = nil
    }

    /// Called by PassthroughManager with each camera frame
    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRunning else { return }

        processingQueue.async { [weak self] in
            self?.runVision(on: pixelBuffer)
        }
    }

    private func runVision(on pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
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

        // Pinch detection
        let pinchDist = hypot(indexPos.x - thumbPos.x, indexPos.y - thumbPos.y)
        let pinchDetected = pinchDist < 0.06

        // Fist / Grab detection
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.isPinching = false
                    self.pinchCooldown = false
                }
            }
        }
    }
}
