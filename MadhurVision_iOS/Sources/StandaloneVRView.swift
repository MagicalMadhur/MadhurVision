import SwiftUI
import SceneKit
import CoreMotion
import Combine

struct StandaloneVRView: View {
    @ObservedObject var appState: AppState
    @StateObject private var vrEngine = VREngine()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Side-by-side (SBS) Stereoscopic Views
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
            
            // Back Button
            VStack {
                HStack {
                    Button(action: {
                        vrEngine.stop()
                        appState.currentMode = .home
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.4))
                            .padding()
                    }
                    Spacer()
                }
                Spacer()
            }
            
            // Dual Crosshairs (one per eye)
            HStack(spacing: 0) {
                Crosshair().frame(maxWidth: .infinity, maxHeight: .infinity)
                Crosshair().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)
        }
        .onAppear { vrEngine.start() }
    }
}

struct Crosshair: View {
    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                .frame(width: 20, height: 20)
            // Inner dot
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 5, height: 5)
        }
    }
}

// MARK: - VR Engine

class VREngine: ObservableObject {
    let scene = SCNScene()
    let leftCameraNode  = SCNNode()
    let rightCameraNode = SCNNode()
    
    private let cameraRig   = SCNNode()
    private let motionManager = CMMotionManager()
    private var browserNode: VRBrowserNode?
    private var handCursor: HandCursorNode?
    private var cancellables = Set<AnyCancellable>()
    
    // IPD — 6.5cm default; override via QR calibration if Cardboard SDK is added
    private let ipd: Float = 0.065
    
    // MARK: - Lifecycle
    
    func start() {
        setupScene()
        setupCameras()
        setupBrowser()
        setupHandCursor()
        startHeadTracking()
        startPassthrough()
        startHandTracking()
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
        browserNode?.cleanup()
        PassthroughManager.shared.stop()
        HandTrackingManager.shared.stop()
        cancellables.removeAll()
    }
    
    // MARK: - Scene Setup
    
    private func setupScene() {
        // Background will be replaced by live passthrough frames
        scene.background.contents = UIColor.black
        
        // Soft ambient light (doesn't affect the browser which uses .constant lighting)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 400
        scene.rootNode.addChildNode(ambient)
    }
    
    private func setupCameras() {
        cameraRig.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraRig)
        
        let leftCam = SCNCamera()
        leftCam.zNear = 0.01
        leftCam.fieldOfView = 90
        leftCameraNode.camera = leftCam
        leftCameraNode.position = SCNVector3(-ipd / 2.0, 0, 0)
        cameraRig.addChildNode(leftCameraNode)
        
        let rightCam = SCNCamera()
        rightCam.zNear = 0.01
        rightCam.fieldOfView = 90
        rightCameraNode.camera = rightCam
        rightCameraNode.position = SCNVector3(ipd / 2.0, 0, 0)
        cameraRig.addChildNode(rightCameraNode)
    }
    
    private func setupBrowser() {
        let browser = VRBrowserNode(
            url: URL(string: "https://www.youtube.com")!,
            width: 2.8,
            height: 1.6
        )
        // Float 2.5 metres ahead, slightly above eye level
        browser.position = SCNVector3(0, 0.1, -2.5)
        
        // Subtle idle animation — gentle floating bob
        let bob = SCNAction.sequence([
            SCNAction.moveBy(x: 0, y: 0.03, z: 0, duration: 2.0),
            SCNAction.moveBy(x: 0, y: -0.03, z: 0, duration: 2.0)
        ])
        browser.runAction(SCNAction.repeatForever(bob))
        
        scene.rootNode.addChildNode(browser)
        self.browserNode = browser
    }
    
    private func setupHandCursor() {
        let cursor = HandCursorNode()
        cursor.browserNode = browserNode
        scene.rootNode.addChildNode(cursor)
        self.handCursor = cursor
    }
    
    // MARK: - Head Tracking (120Hz)
    
    private func startHeadTracking() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: OperationQueue.main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.cameraRig.eulerAngles = SCNVector3(
                x: Float(motion.attitude.pitch),
                y: Float(motion.attitude.yaw),
                z: Float(motion.attitude.roll)
            )
        }
    }
    
    // MARK: - Passthrough Camera
    
    private func startPassthrough() {
        PassthroughManager.shared.start(scene: scene)
    }
    
    // MARK: - Hand Tracking
    
    private func startHandTracking() {
        HandTrackingManager.shared.start()
        
        // Observe hand state changes and update the cursor
        HandTrackingManager.shared.$indexTipPosition
            .combineLatest(
                HandTrackingManager.shared.$isPinching,
                HandTrackingManager.shared.$scrollDelta
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] fingerPos, isPinching, scrollDelta in
                guard let self, let cursor = self.handCursor else { return }
                cursor.update(
                    fingerPos:   fingerPos,
                    cameraNode:  self.leftCameraNode,  // use left eye for raycasting
                    scene:       self.scene,
                    isPinching:  isPinching,
                    scrollDelta: scrollDelta
                )
            }
            .store(in: &cancellables)
    }
}
