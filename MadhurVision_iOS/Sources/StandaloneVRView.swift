import SwiftUI
import SceneKit
import CoreMotion

struct StandaloneVRView: View {
    @ObservedObject var appState: AppState
    
    // We create the scene and node manager once
    @StateObject private var vrEngine = VREngine()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Side-by-side (SBS) VR Views
            HStack(spacing: 0) {
                // Left Eye
                SceneView(
                    scene: vrEngine.scene,
                    pointOfView: vrEngine.leftCameraNode,
                    options: [.rendersContinuously]
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Right Eye
                SceneView(
                    scene: vrEngine.scene,
                    pointOfView: vrEngine.rightCameraNode,
                    options: [.rendersContinuously]
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            
            // Back Button (hidden during immersion, visible on tap)
            VStack {
                HStack {
                    Button(action: {
                        vrEngine.stop()
                        appState.currentMode = .home
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.5))
                            .padding()
                    }
                    Spacer()
                }
                Spacer()
            }
            
            // Center Reticle (Crosshair)
            HStack(spacing: 0) {
                Crosshair()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Crosshair()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false) // Don't block touches
        }
        .onAppear {
            vrEngine.start()
        }
    }
}

struct Crosshair: View {
    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.8))
            .frame(width: 8, height: 8)
            .shadow(color: .black, radius: 2)
    }
}

class VREngine: ObservableObject {
    let scene = SCNScene()
    let leftCameraNode = SCNNode()
    let rightCameraNode = SCNNode()
    
    private let cameraRig = SCNNode()
    private let motionManager = CMMotionManager()
    private var browserNode: VRBrowserNode?
    
    // IPD (Inter-pupillary distance) in meters
    private let ipd: Float = 0.065
    
    func start() {
        setupScene()
        setupCameras()
        setupBrowser()
        startHeadTracking()
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
        browserNode?.cleanup()
    }
    
    private func setupScene() {
        // Simple dark gray background
        scene.background.contents = UIColor(white: 0.1, alpha: 1.0)
        
        // Ambient light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 1000
        scene.rootNode.addChildNode(ambientLight)
    }
    
    private func setupCameras() {
        // Base rig holds both cameras
        cameraRig.position = SCNVector3(x: 0, y: 0, z: 0)
        scene.rootNode.addChildNode(cameraRig)
        
        // Left camera
        let leftCam = SCNCamera()
        leftCam.zNear = 0.01
        leftCameraNode.camera = leftCam
        leftCameraNode.position = SCNVector3(x: -ipd / 2.0, y: 0, z: 0)
        cameraRig.addChildNode(leftCameraNode)
        
        // Right camera
        let rightCam = SCNCamera()
        rightCam.zNear = 0.01
        rightCameraNode.camera = rightCam
        rightCameraNode.position = SCNVector3(x: ipd / 2.0, y: 0, z: 0)
        cameraRig.addChildNode(rightCameraNode)
    }
    
    private func setupBrowser() {
        // Spawn browser 2 meters in front
        let browser = VRBrowserNode(url: URL(string: "https://www.youtube.com")!, width: 2.5, height: 1.4)
        browser.position = SCNVector3(x: 0, y: 0, z: -2.0)
        scene.rootNode.addChildNode(browser)
        self.browserNode = browser
    }
    
    private func startHeadTracking() {
        guard motionManager.isDeviceMotionAvailable else { return }
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 120.0 // 120Hz tracking
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: OperationQueue.main) { [weak self] (motion, error) in
            guard let self = self, let motion = motion else { return }
            
            // Map attitude to SceneKit Euler Angles
            // Note: SceneKit euler angles are pitch (x), yaw (y), roll (z)
            // iOS landscape mapping requires some swizzling depending on orientation
            self.cameraRig.eulerAngles = SCNVector3(
                x: Float(motion.attitude.pitch),
                y: Float(motion.attitude.yaw),
                z: Float(motion.attitude.roll)
            )
        }
    }
}
