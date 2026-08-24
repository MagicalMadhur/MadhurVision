import AVFoundation
import SceneKit
import UIKit
import CoreImage

/// Pipes the rear camera feed directly into SceneKit's scene background
/// to create a "passthrough" mixed-reality effect.
/// Also shares frames with HandTrackingManager (single session, no conflicts).
class PassthroughManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = PassthroughManager()

    weak var scene: SCNScene?

    public let captureSession = AVCaptureSession()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "PassthroughQueue", qos: .userInteractive)

    private override init() {
        super.init()
    }

    func start(scene: SCNScene) {
        self.scene = scene
        guard !captureSession.isRunning else { return }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

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

        captureSession.commitConfiguration()

        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
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

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Feed raw frame to HandTrackingManager (runs its own async vision queue)
        HandTrackingManager.shared.processFrame(pixelBuffer)
    }
}

    func updateOrientation(_ orientation: AVCaptureVideoOrientation) {
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
        }
    }
