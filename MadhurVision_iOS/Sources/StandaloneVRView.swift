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
            
            GeometryReader { geo in
                HStack(spacing: 0) {
                    // Left Eye
                    SceneView(
                        scene: vrEngine.scene,
                        pointOfView: vrEngine.leftCameraNode,
                        options: [.rendersContinuously]
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { location in
                        let size = CGSize(width: geo.size.width / 2.0, height: geo.size.height)
                        vrEngine.handleDirectScreenTap(location: location, isLeftEye: true, size: size)
                    }
                    
                    // Right Eye
                    SceneView(
                        scene: vrEngine.scene,
                        pointOfView: vrEngine.rightCameraNode,
                        options: [.rendersContinuously]
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { location in
                        let size = CGSize(width: geo.size.width / 2.0, height: geo.size.height)
                        vrEngine.handleDirectScreenTap(location: location, isLeftEye: false, size: size)
                    }
                }
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
    
    enum OSState {
        case loading
        case desktop
    }
    
    @Published var browserScale: CGFloat = 1.0  // 1.0 = default, user can resize
    @Published var osState: OSState = .loading
    
    private let cameraRig   = SCNNode()
    private let motionManager = CMMotionManager()
    
    // OS Nodes
    private var loadingNode: VRLoadingNode?
    private var dockNode: VRDockNode?
    private var activeWindowNode: SCNNode?
    
    private var handCursor: HandCursorNode?
    private var mouseCursor: MouseCursorNode?
    
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
        setupHandCursor()
        setupMouseCursor()
        startHeadTracking()
        startPassthrough()
        startTracking()
        bootOS()
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
        if let browser = activeWindowNode as? VRBrowserNode {
            browser.cleanup()
        }
        PassthroughManager.shared.stop()
        HandTrackingManager.shared.stop()
        cancellables.removeAll()
    }
    
    // MARK: - Resize
    
    func resizeBrowser(by delta: CGFloat) {
        browserScale = max(0.3, min(2.0, browserScale + delta))
        let s = Float(browserScale)
        activeWindowNode?.scale = SCNVector3(s, s, s)
    }
    
    // MARK: - Direct Screen Taps (Fallback for AssistiveTouch)
    
    func handleDirectScreenTap(location: CGPoint, isLeftEye: Bool, size: CGSize) {
        let cameraNode = isLeftEye ? leftCameraNode : rightCameraNode
        
        // Convert screen coordinate to normalized device coordinates (-1 to 1)
        let ndcX = Float(location.x / size.width) * 2.0 - 1.0
        let ndcY = -(Float(location.y / size.height) * 2.0 - 1.0)
        
        // Cast ray into the scene
        let rayDirection = SCNVector3(ndcX * 1.5, ndcY * 1.5, -3.0)
        let worldOrigin = cameraNode.worldPosition
        let worldDirection = cameraNode.convertVector(rayDirection, to: nil)
        
        let rayEnd = SCNVector3(
            worldOrigin.x + worldDirection.x,
            worldOrigin.y + worldDirection.y,
            worldOrigin.z + worldDirection.z
        )
        
        let hits = scene.rootNode.hitTestWithSegment(
            from: worldOrigin,
            to: rayEnd,
            options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue]
        )
        
        if let hit = hits.first {
            handleHit(hit)
        }
    }
    
    private func handleHit(_ hit: SCNHitTestResult) {
        if let name = hit.node.name {
            if name == "dock_browser" {
                launchApp(type: .browser)
                return
            } else if name == "dock_settings" {
                launchApp(type: .settings)
                return
            }
        }
        
        // If it's a browser window, send click
        let node = hit.node
        if let browser = activeWindowNode as? VRBrowserNode, node === browser || node.parent === browser {
            let uv = CGPoint(x: CGFloat(hit.textureCoordinates(withMappingChannel: 0).x),
                             y: CGFloat(1.0 - hit.textureCoordinates(withMappingChannel: 0).y))
            browser.simulateClick(at: uv)
        }
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
    
    private func bootOS() {
        osState = .loading
        let loader = VRLoadingNode()
        // Center it slightly higher than eye level
        loader.position = SCNVector3(0, 0.1, browserDistance)
        scene.rootNode.addChildNode(loader)
        self.loadingNode = loader
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.transitionToDesktop()
        }
    }
    
    private func transitionToDesktop() {
        osState = .desktop
        
        // Fade out loading screen
        let fadeOut = SCNAction.fadeOut(duration: 0.5)
        loadingNode?.runAction(fadeOut) { [weak self] in
            self?.loadingNode?.removeFromParentNode()
            self?.loadingNode = nil
        }
        
        // Spawn Dock on the left
        let dock = VRDockNode()
        dock.position = SCNVector3(-1.8, 0.1, browserDistance + 0.2) // closer to user, left side
        dock.eulerAngles = SCNVector3(0, Float.pi / 10, 0) // turned slightly towards user
        dock.opacity = 0
        scene.rootNode.addChildNode(dock)
        self.dockNode = dock
        
        dock.runAction(SCNAction.fadeIn(duration: 0.5))
    }
    
    enum AppType {
        case browser
        case settings
    }
    
    private func launchApp(type: AppType) {
        // Cleanup old app
        if let browser = activeWindowNode as? VRBrowserNode {
            browser.cleanup()
        }
        activeWindowNode?.removeFromParentNode()
        
        let newNode: SCNNode
        switch type {
        case .browser:
            newNode = VRBrowserNode(
                url: URL(string: "https://www.google.com")!,
                width: baseBrowserWidth,
                height: baseBrowserHeight
            )
        case .settings:
            newNode = VRSettingsNode()
        }
        
        newNode.position = SCNVector3(0.3, 0.1, browserDistance) // slightly shifted right to make room for dock
        let bob = SCNAction.sequence([
            SCNAction.moveBy(x: 0, y: 0.03, z: 0, duration: 2.0),
            SCNAction.moveBy(x: 0, y: -0.03, z: 0, duration: 2.0)
        ])
        newNode.runAction(SCNAction.repeatForever(bob))
        
        // Appear animation
        newNode.scale = SCNVector3(0.01, 0.01, 0.01)
        newNode.runAction(SCNAction.scale(to: CGFloat(browserScale), duration: 0.4))
        
        scene.rootNode.addChildNode(newNode)
        self.activeWindowNode = newNode
    }
    
    private func setupHandCursor() {
        let cursor = HandCursorNode()
        cursor.onClick = { [weak self] hit in
            self?.handleHit(hit)
        }
        scene.rootNode.addChildNode(cursor)
        self.handCursor = cursor
    }
    
    private func setupMouseCursor() {
        let cursor = MouseCursorNode()
        cursor.onClick = { [weak self] hit in
            self?.handleHit(hit)
        }
        scene.rootNode.addChildNode(cursor)
        self.mouseCursor = cursor
    }
    
    // MARK: - Head Tracking (120Hz)
    
    private var hasCenteredBrowser = false
    
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
            
            // Auto-center the active window on the very first valid tracking frame
            if !self.hasCenteredBrowser {
                self.hasCenteredBrowser = true
                
                // Spawn it exactly browserDistance in front of where the user is looking NOW
                let localFront = SCNVector3(0, 0, self.browserDistance)
                let worldFront = self.cameraRig.convertPosition(localFront, to: nil)
                
                self.loadingNode?.position = worldFront
                self.loadingNode?.eulerAngles = self.cameraRig.eulerAngles
            }
        }
    }
    
    // MARK: - Passthrough Camera
    
    private func startPassthrough() {
        PassthroughManager.shared.start(scene: scene)
    }
    
    // Grab State
    private var isCurrentlyGrabbing = false
    private var grabOffset: SCNVector3 = SCNVector3Zero
    
    // MARK: - Tracking
    
    private func startTracking() {
        HandTrackingManager.shared.start()
        MouseTrackingManager.shared.start()
        
        let ht = HandTrackingManager.shared
        let mt = MouseTrackingManager.shared
        
        // Combine mouse data stream
        mt.$virtualPosition
            .combineLatest(mt.$isLeftClicking, mt.$isMouseActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] (pos, isClicking, isActive) in
                guard let self else { return }
                if isActive {
                    self.mouseCursor?.update(virtualPosition: pos,
                                             cameraNode: self.leftCameraNode,
                                             scene: self.scene,
                                             isClicking: isClicking)
                }
            }
            .store(in: &cancellables)
        
        // Combine all hand data into one stream
        ht.$indexTipPosition
            .combineLatest(ht.$isPinching, ht.$scrollDelta)
            .combineLatest(ht.$isGrabbing, ht.$grabPosition)
            .receive(on: RunLoop.main)
            .sink { [weak self] combined in
                guard let self else { return }
                let ((fingerPos, isPinching, scrollDelta), isGrabbing, grabPosition) = combined
                
                // Window grab & move: fist clench drags the active window in 3D
                if isGrabbing, let activeNode = self.activeWindowNode {
                    // 1. Convert 2D hand position to 3D point at Z = browser distance relative to camera
                    // Apply sensitivity multiplier so small hand movements cover the whole space
                    let sensitivity: Float = 2.5
                    let ndcX = Float(grabPosition.x * 2.0 - 1.0) * sensitivity
                    let ndcY = Float(grabPosition.y * 2.0 - 1.0) * sensitivity
                    
                    // Scale to world dimensions at z = 2.5
                    let worldX = ndcX * 2.5
                    let worldY = ndcY * 2.5
                    let localPoint = SCNVector3(worldX, -worldY, self.browserDistance) // Invert Y
                    
                    // Convert local point to world space relative to the camera
                    let worldPoint = self.leftCameraNode.convertPosition(localPoint, to: nil)
                    
                    if !self.isCurrentlyGrabbing {
                        self.isCurrentlyGrabbing = true
                        // Record offset from hand ray to browser center
                        self.grabOffset = SCNVector3(
                            activeNode.position.x - worldPoint.x,
                            activeNode.position.y - worldPoint.y,
                            activeNode.position.z - worldPoint.z
                        )
                    }
                    
                    let targetPos = SCNVector3(
                        worldPoint.x + self.grabOffset.x,
                        worldPoint.y + self.grabOffset.y,
                        worldPoint.z + self.grabOffset.z
                    )
                    
                    // Smoothly interpolate to target position
                    activeNode.position.x += (targetPos.x - activeNode.position.x) * 0.15
                    activeNode.position.y += (targetPos.y - activeNode.position.y) * 0.15
                    activeNode.position.z += (targetPos.z - activeNode.position.z) * 0.15
                    
                    // Keep the window facing the user!
                    activeNode.eulerAngles = self.cameraRig.eulerAngles
                    
                    return  // skip cursor update while grabbing
                } else {
                    self.isCurrentlyGrabbing = false
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
