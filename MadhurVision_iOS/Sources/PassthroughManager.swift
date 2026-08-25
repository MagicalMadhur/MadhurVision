import AVFoundation
import SceneKit
import UIKit
import CoreImage

/// Pipes the rear camera feed directly into SceneKit's scene background
/// as a CGImage to create a stereoscopic "passthrough" mixed-reality effect
/// that renders equally for both left and right eye views.
/// Also shares frames with HandTrackingManager (single session, no conflicts).
class PassthroughManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = PassthroughManager()

    weak var scene: SCNScene?

    public let captureSession = AVCaptureSession()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "PassthroughQueue", qos: .userInteractive)
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: false
    ])

    private var isConfigured = false
    private var frameCount = 0

    private override init() {
        super.init()
    }

    /// Configures camera connections
    @discardableResult
    func prepare() -> Bool {
        guard !isConfigured else { return true }
        
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        AppLogger.shared.log("[PassthroughManager] Camera Authorization Status: \(authStatus.rawValue)")
        // Configure Audio Session for background video & system audio playback
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
            AppLogger.shared.log("[PassthroughManager] AudioSession configured with playback + mixWithOthers")
        } catch {
            AppLogger.shared.log("[PassthroughManager] AudioSession warning: \(error.localizedDescription)")
        }
        
        isConfigured = true
        captureSession.automaticallyConfiguresApplicationAudioSession = false
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            captureSession.commitConfiguration()
            isConfigured = false
            AppLogger.shared.log("[PassthroughManager] ERROR: Could not access rear camera device")
            return false
        }
        
        AppLogger.shared.log("[PassthroughManager] Rear camera found: \(device.localizedName)")

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            AppLogger.shared.log("[PassthroughManager] Camera input attached")
        }

        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            AppLogger.shared.log("[PassthroughManager] Video output attached")
        }

        captureSession.commitConfiguration()

        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            AppLogger.shared.log("[PassthroughManager] Camera framerate set to 30 FPS")
        } catch {
            AppLogger.shared.log("[PassthroughManager] Warning: Could not configure framerate: \(error)")
        }

        return true
    }

    func start(scene: SCNScene) {
        self.scene = scene
        guard prepare() else {
            AppLogger.shared.log("[PassthroughManager] prepare() failed, cannot start session")
            return
        }
        
        guard !captureSession.isRunning else { return }

        processingQueue.async {
            AppLogger.shared.log("[PassthroughManager] Starting captureSession...")
            self.captureSession.startRunning()
            AppLogger.shared.log("[PassthroughManager] captureSession isRunning = \(self.captureSession.isRunning)")
        }
    }

    func stop() {
        AppLogger.shared.log("[PassthroughManager] Stopping captureSession")
        captureSession.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        frameCount += 1
        if frameCount == 1 {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            AppLogger.shared.log("[PassthroughManager] First frame received! Dimensions: \(width)x\(height)")
        }
        
        // Convert CVPixelBuffer to CGImage for SceneKit background.
        // SceneKit requires CGImage or UIImage (it ignores raw CIImage).
        // Since both eyes render the same SCNScene, both eyes display the camera feed!
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            DispatchQueue.main.async { [weak self] in
                self?.scene?.background.contents = cgImage
            }
        }
        
        // Feed raw frame to HandTrackingManager (runs its own async vision queue)
        HandTrackingManager.shared.processFrame(pixelBuffer)
    }

    func updateOrientation(_ orientation: AVCaptureVideoOrientation) {
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
        }
    }
}
