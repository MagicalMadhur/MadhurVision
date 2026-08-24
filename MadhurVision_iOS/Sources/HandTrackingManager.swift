import AVFoundation
import Vision
import Combine

/// Detects hand pose from camera frames and publishes
/// normalized finger positions and gesture states.
class HandTrackingManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = HandTrackingManager()

    // Published values consumed by HandCursorNode
    @Published var indexTipPosition: CGPoint = .zero   // 0–1 normalized screen coords
    @Published var isPinching: Bool = false
    @Published var scrollDelta: CGFloat = 0.0
    @Published var isGrabbing: Bool = false             // fist clench = grab window
    @Published var grabDelta: CGPoint = .zero            // how much the grabbed fist moved

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "HandTrackingQueue", qos: .userInteractive)

    // Vision request
    private lazy var handPoseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()

    // Tracking state
    private var previousPalmY: CGFloat? = nil
    private var previousGrabPos: CGPoint? = nil
    private var pinchCooldown = false

    private override init() {
        super.init()
    }

    func start() {
        guard !captureSession.isRunning else { return }

        captureSession.sessionPreset = .vga640x480  // Low res is fine for gesture detection

        // Prefer front camera for hand tracking (hands naturally in front of face)
        // Fall back to rear camera on devices that don't support simultaneous capture
        let position: AVCaptureDevice.Position = .front
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else {
            print("[HandTrackingManager] Could not access camera for hand tracking")
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        processingQueue.async {
            self.captureSession.startRunning()
        }
    }

    func stop() {
        captureSession.stopRunning()
        previousPalmY = nil
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        do {
            try handler.perform([handPoseRequest])
        } catch {
            return
        }

        guard let observation = handPoseRequest.results?.first else {
            // No hand detected — reset
            DispatchQueue.main.async { self.indexTipPosition = .zero }
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
              indexTip.confidence > 0.3,
              thumbTip.confidence > 0.3 else { return }

        // Vision coords: origin bottom-left, flip Y for screen coords
        let indexPos = CGPoint(x: indexTip.location.x,
                               y: 1.0 - indexTip.location.y)
        let thumbPos = CGPoint(x: thumbTip.location.x,
                               y: 1.0 - thumbTip.location.y)

        // Pinch detection — distance between index tip and thumb tip
        let pinchDist = hypot(indexPos.x - thumbPos.x, indexPos.y - thumbPos.y)
        let pinchDetected = pinchDist < 0.06

        // Fist / Grab detection — all fingertips below their MCP joints
        let isFist = (indexTip.location.y < indexMCP.location.y) &&
                     (middleTip.location.y < middleMCP.location.y) &&
                     (ringTip.location.y < ringMCP.location.y)

        let wristPos = CGPoint(x: wrist.location.x, y: 1.0 - wrist.location.y)

        // Grab delta — how much the fist moved since last frame
        var gDelta = CGPoint.zero
        if isFist, let prev = previousGrabPos {
            gDelta = CGPoint(x: wristPos.x - prev.x, y: wristPos.y - prev.y)
        }
        previousGrabPos = isFist ? wristPos : nil

        // Scroll detection — track wrist vertical movement (only when NOT grabbing)
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
            self.grabDelta = gDelta

            // Debounce pinch to avoid rapid-fire clicks
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
