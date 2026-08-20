import Foundation
import CoreMotion

class MotionManager {
    static let shared = MotionManager()
    
    private let motionManager = CMMotionManager()
    
    private init() {}
    
    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60Hz
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: OperationQueue.main) { [weak self] (motion, error) in
            guard let motion = motion else { return }
            
            // Send yaw, pitch, roll to PC
            let attitude = motion.attitude
            NetworkManager.shared.sendIMUData(
                pitch: attitude.pitch,
                yaw: attitude.yaw,
                roll: attitude.roll
            )
        }
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}
