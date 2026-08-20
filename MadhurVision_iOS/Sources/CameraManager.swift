import Foundation
import AVFoundation
import UIKit
import CoreImage

class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = CameraManager()
    
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    
    private override init() {
        super.init()
    }
    
    func start() {
        guard !captureSession.isRunning else { return }
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.setupCamera()
            self.captureSession.startRunning()
        }
    }
    
    private func setupCamera() {
        captureSession.sessionPreset = .hd1280x720
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            print("Failed to get camera device")
            return
        }
        
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        // Lock to 60fps if supported
        do {
            try device.lockForConfiguration()
            let maxFps = device.activeFormat.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30.0
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(maxFps > 60 ? 60 : maxFps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(maxFps > 60 ? 60 : maxFps))
            device.unlockForConfiguration()
        } catch {
            print("Could not configure framerate")
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard NetworkManager.shared.isConnected else { return }
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        
        let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        let dataSize = bytesPerRow * height
        if let baseAddress = baseAddress {
            let data = Data(bytes: baseAddress, count: dataSize)
            // Compress to JPEG for transmission
            if let cgImage = CGImage.create(from: imageBuffer),
               let uiImage = UIImage(cgImage: cgImage),
               let jpegData = uiImage.jpegData(compressionQuality: 0.6) {
                NetworkManager.shared.sendVideoFrame(data: jpegData)
            }
        }
        
        CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
    }
}

extension CGImage {
    static func create(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}
