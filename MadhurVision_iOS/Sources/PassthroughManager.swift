import AVFoundation
import SceneKit
import UIKit

/// Pipes the rear camera feed directly into SceneKit's scene background
/// to create a "passthrough" mixed-reality effect.
class PassthroughManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = PassthroughManager()

    // The SceneKit scene whose background we will update
    weak var scene: SCNScene?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "PassthroughQueue", qos: .userInteractive)

    private override init() {
        super.init()
    }

    func start(scene: SCNScene) {
        self.scene = scene
        guard !captureSession.isRunning else { return }

        captureSession.sessionPreset = .hd1920x1080

        // Use the rear wide-angle camera for passthrough
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            print("[PassthroughManager] Could not access rear camera")
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // Lock to 60fps for smooth passthrough
        do {
            try device.lockForConfiguration()
            let maxFps = device.activeFormat.videoSupportedFrameRateRanges
                .compactMap { $0.maxFrameRate }
                .max() ?? 30
            let fps = min(maxFps, 60)
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(fps))
            device.unlockForConfiguration()
        } catch {
            print("[PassthroughManager] Could not configure framerate")
        }

        processingQueue.async {
            self.captureSession.startRunning()
        }
    }

    func stop() {
        captureSession.stopRunning()
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Rotate to landscape (SceneKit scene background fills the full screen)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(.right) // rear camera in landscape needs 90° rotation

        let context = CIContext(options: nil)
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let cgImage = context.createCGImage(ciImage,
                                                  from: CGRect(x: 0, y: 0,
                                                               width: height,  // swapped — post-rotation
                                                               height: width)) else { return }

        // Push to SceneKit on the main thread
        DispatchQueue.main.async { [weak self] in
            self?.scene?.background.contents = cgImage
        }
    }
}
