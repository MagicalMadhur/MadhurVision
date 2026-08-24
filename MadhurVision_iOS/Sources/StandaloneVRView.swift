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
                SceneView(
                    scene: vrEngine.scene,
                    pointOfView: vrEngine.leftCameraNode,
                    options: [.rendersContinuously]
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                SceneView(
                    scene: vrEngine.scene,
                    pointOfView: vrEngine.rightCameraNode,
                    options: [.rendersContinuously]
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            
            // Back + Window Size Controls (overlaid on left eye)
            VStack {
                HStack(spacing: 12) {
                    // Exit button
                    Button(action: {
                        vrEngine.stop()
                        appState.currentMode = .home
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    
                    Spacer()
                    
                    // Window size controls
                    Button(action: { vrEngine.resizeBrowser(by: -0.2) }) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    
                    Text(String(format: "%.0f%%", vrEngine.browserScale * 100))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                    
                    Button(action: { vrEngine.resizeBrowser(by: 0.2) }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                Spacer()
            }
            
            // Dual Crosshairs
            HStack(spacing: 0) {
                Crosshair().frame(maxWidth: .infinity, maxHeight: .infinity)
                Crosshair().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)
        }
        .onAppear { vrEngine.start() }
        .statusBarHidden(true)
    }
}

struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                .frame(width: 20, height: 20)
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
    
    @Published var browserScale: CGFloat = 1.0  // 1.0 = default, user can resize
    
    private let cameraRig   = SCNNode()
    private let motionManager = CMMotionManager()
    private var browserNode: VRBrowserNode?
    private var handCursor: HandCursorNode?
    private var cancellables = Set<AnyCancellable>()
    
    // Base browser dimensions (before scaling)
    private let baseBrowserWidth:  CGFloat = 2.8
    private let baseBrowserHeight: CGFloat = 1.6
    private let browserDistance:    Float  = -2.5
    
    // IPD
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
    
    // MARK: - Resize
    
    func resizeBrowser(by delta: CGFloat) {
        browserScale = max(0.3, min(2.0, browserScale + delta))
        let s = Float(browserScale)
        browserNode?.scale = SCNVector3(s, s, s)
    }
    
    // MARK: - Scene Setup
    
    private func setupScene() {
        scene.background.contents = UIColor.black
        
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
            width: baseBrowserWidth,
            height: baseBrowserHeight
        )
        // Start floating 2.5m ahead, slightly above eye level
        browser.position = SCNVector3(0, 0.1, browserDistance)
        
        // Subtle idle bob
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
        
        let ht = HandTrackingManager.shared
        
        // Combine all hand data into one stream
        ht.$indexTipPosition
            .combineLatest(ht.$isPinching, ht.$scrollDelta)
            .combineLatest(ht.$isGrabbing, ht.$grabDelta)
            .receive(on: RunLoop.main)
            .sink { [weak self] combined in
                guard let self else { return }
                let ((fingerPos, isPinching, scrollDelta), isGrabbing, grabDelta) = combined
                
                // Window grab & move: fist clench drags the browser in 3D
                if isGrabbing, let browser = self.browserNode {
                    let moveSpeed: Float = 5.0
                    let dx = Float(grabDelta.x) * moveSpeed
                    let dy = Float(-grabDelta.y) * moveSpeed
                    browser.position = SCNVector3(
                        browser.position.x + dx,
                        browser.position.y + dy,
                        browser.position.z
                    )
                    return  // skip cursor update while grabbing
                }
                
                // Normal cursor behavior
                self.handCursor?.update(
                    fingerPos:   fingerPos,
                    cameraNode:  self.leftCameraNode,
                    scene:       self.scene,
                    isPinching:  isPinching,
                    scrollDelta: scrollDelta
                )
            }
            .store(in: &cancellables)
    }
}
