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
            
            // Top HUD Controls (overlaid for easy access)
            VStack {
                HStack(spacing: 14) {
                    // Exit button
                    Button(action: {
                        vrEngine.stop()
                        appState.currentMode = .home
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Spacer()
                    
                    // Recalibrate Center Button
                    Button(action: { vrEngine.recalibrateView() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "scope")
                            Text("Center")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.5))
                        .foregroundColor(.cyan)
                        .cornerRadius(8)
                    }
                    
                    // Window size controls (projector-style scale)
                    Button(action: { vrEngine.scaleMonitor(by: -0.15) }) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Text(String(format: "%.0f%%", vrEngine.monitorScale * 100))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                    
                    Button(action: { vrEngine.scaleMonitor(by: 0.15) }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
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
        .onDisappear { vrEngine.stop() }
        .statusBarHidden(true)
    }
}

struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: 22, height: 22)
            Circle()
                .fill(Color.cyan.opacity(0.8))
                .frame(width: 4, height: 4)
        }
    }
}

// MARK: - VR Engine

class VREngine: ObservableObject {
    let scene = SCNScene()
    let leftCameraNode  = SCNNode()
    let rightCameraNode = SCNNode()
    
    @Published var monitorScale: CGFloat = 1.0
    
    private let cameraRig   = SCNNode()
    private let motionManager = CMMotionManager()
    
    // Single unified monitor
    private var monitorNode: VRMonitorNode?
    
    private var handCursor: HandCursorNode?
    private var mouseCursor: MouseCursorNode?
    
    private var cancellables = Set<AnyCancellable>()
    
    // Default Monitor distance in front of user (meters)
    private let monitorDistance: Float = -2.2
    
    // Default IPD in meters (65mm)
    private var ipd: Float = 0.065
    
    // MARK: - Lifecycle
    
    func start() {
        setupScene()
        setupCameras()
        setupHandCursor()
        setupMouseCursor()
        startHeadTracking()
        startPassthrough()
        startTracking()
        spawnMonitor()
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
        monitorNode?.cleanup()
        PassthroughManager.shared.stop()
        HandTrackingManager.shared.stop()
        cancellables.removeAll()
    }
    
    // MARK: - Scale & Settings
    
    func scaleMonitor(by delta: CGFloat) {
        setMonitorScale(monitorScale + delta)
    }
    
    func setMonitorScale(_ newScale: CGFloat) {
        monitorScale = max(0.4, min(2.8, newScale))
        let s = Float(monitorScale)
        monitorNode?.scale = SCNVector3(s, s, s)
    }
    
    func setIPD(_ newIPD: Float) {
        ipd = max(0.050, min(0.080, newIPD))
        leftCameraNode.position = SCNVector3(-ipd / 2.0, 0, 0)
        rightCameraNode.position = SCNVector3(ipd / 2.0, 0, 0)
    }
    
    func setPassthrough(enabled: Bool) {
        if enabled {
            PassthroughManager.shared.start(scene: scene)
        } else {
            PassthroughManager.shared.stop()
            scene.background.contents = UIColor.black
        }
    }
    
    // MARK: - Recalibrate Center View
    
    func recalibrateView() {
        guard let monitor = monitorNode else { return }
        // Center the monitor directly in front along the current camera yaw
        let currentYaw = cameraRig.eulerAngles.y
        let dist = -monitorDistance
        
        let targetX = -sin(currentYaw) * dist
        let targetZ = -cos(currentYaw) * dist
        
        monitor.position = SCNVector3(targetX, 0.05, targetZ)
        monitor.eulerAngles = SCNVector3(0, currentYaw, 0)
    }
    
    // MARK: - Direct Screen Taps (Fallback)
    
    func handleDirectScreenTap(location: CGPoint, isLeftEye: Bool, size: CGSize) {
        let cameraNode = isLeftEye ? leftCameraNode : rightCameraNode
        
        let ndcX = Float(location.x / size.width) * 2.0 - 1.0
        let ndcY = -(Float(location.y / size.height) * 2.0 - 1.0)
        
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
        let node = hit.node
        if let monitor = monitorNode,
           node === monitor || node.parent === monitor || node.name == "monitor_border" {
            let uv = CGPoint(
                x: CGFloat(hit.textureCoordinates(withMappingChannel: 0).x),
                y: CGFloat(1.0 - hit.textureCoordinates(withMappingChannel: 0).y)
            )
            monitor.simulateClick(at: uv)
        }
    }
    
    // MARK: - Scene Setup
    
    private func setupScene() {
        scene.background.contents = UIColor.black
        
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 600
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
    
    // MARK: - Spawn Single Monitor
    
    private func spawnMonitor() {
        let monitor = VRMonitorNode()
        
        // Wire up settings callbacks from the Web OS
        monitor.onScaleChanged = { [weak self] scale in
            self?.setMonitorScale(scale)
        }
        monitor.onIPDChanged = { [weak self] ipd in
            self?.setIPD(ipd)
        }
        monitor.onRecalibrateRequested = { [weak self] in
            self?.recalibrateView()
        }
        monitor.onPassthroughToggled = { [weak self] enabled in
            self?.setPassthrough(enabled: enabled)
        }
        
        // Position directly in front at eye level
        monitor.position = SCNVector3(0, 0.05, monitorDistance)
        monitor.eulerAngles = SCNVector3(0, 0, 0)
        
        // Gentle resting float animation
        let bob = SCNAction.sequence([
            SCNAction.moveBy(x: 0, y: 0.015, z: 0, duration: 2.5),
            SCNAction.moveBy(x: 0, y: -0.015, z: 0, duration: 2.5)
        ])
        monitor.runAction(SCNAction.repeatForever(bob))
        
        scene.rootNode.addChildNode(monitor)
        self.monitorNode = monitor
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
    
    // MARK: - Landscape VR Head Tracking (120Hz)
    
    private var hasAlignedMonitor = false
    
    private func startHeadTracking() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
        
        // Use reference frame with Z vertical
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: OperationQueue.main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            
            // In Landscape Left (phone rotated 90 deg counter-clockwise):
            // - Tilting up/down is rotation around the phone's long axis (-roll)
            // - Panning left/right is rotation around gravity vertical (-yaw)
            // - Level horizon is maintained with 0 roll
            let pitch = Float(-motion.attitude.roll)
            let yaw   = Float(-motion.attitude.yaw)
            
            self.cameraRig.eulerAngles = SCNVector3(pitch, yaw, 0)
            
            // On startup, align monitor directly in front of the user's initial heading
            if !self.hasAlignedMonitor {
                self.hasAlignedMonitor = true
                self.recalibrateView()
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
    
    // MARK: - Tracking & Gestures
    
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
        
        // Combine all hand tracking data into one stream
        ht.$indexTipPosition
            .combineLatest(ht.$isPinching, ht.$scrollDelta)
            .combineLatest(ht.$isGrabbing, ht.$grabPosition)
            .receive(on: RunLoop.main)
            .sink { [weak self] combined in
                guard let self else { return }
                let ((fingerPos, isPinching, scrollDelta), isGrabbing, grabPosition) = combined
                
                // Fist Clench / Grab: drags the single monitor smoothly in 3D space
                if isGrabbing, let monitor = self.monitorNode {
                    let sensitivity: Float = 2.5
                    let ndcX = Float(grabPosition.x * 2.0 - 1.0) * sensitivity
                    let ndcY = Float(grabPosition.y * 2.0 - 1.0) * sensitivity
                    
                    let worldX = ndcX * 2.5
                    let worldY = ndcY * 2.5
                    let localPoint = SCNVector3(worldX, -worldY, self.monitorDistance)
                    let worldPoint = self.leftCameraNode.convertPosition(localPoint, to: nil)
                    
                    if !self.isCurrentlyGrabbing {
                        self.isCurrentlyGrabbing = true
                        self.grabOffset = SCNVector3(
                            monitor.position.x - worldPoint.x,
                            monitor.position.y - worldPoint.y,
                            monitor.position.z - worldPoint.z
                        )
                    }
                    
                    let targetPos = SCNVector3(
                        worldPoint.x + self.grabOffset.x,
                        worldPoint.y + self.grabOffset.y,
                        worldPoint.z + self.grabOffset.z
                    )
                    
                    // Smoothly interpolate to target position
                    monitor.position.x += (targetPos.x - monitor.position.x) * 0.15
                    monitor.position.y += (targetPos.y - monitor.position.y) * 0.15
                    monitor.position.z += (targetPos.z - monitor.position.z) * 0.15
                    
                    // Keep the monitor locked upright facing the user
                    monitor.eulerAngles = SCNVector3(0, self.cameraRig.eulerAngles.y, 0)
                    
                    return // skip cursor raycast while grabbing
                } else {
                    self.isCurrentlyGrabbing = false
                }
                
                // Normal Hand Cursor Update
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
