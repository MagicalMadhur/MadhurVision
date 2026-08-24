import SwiftUI
import SceneKit
import CoreMotion
import Combine
import AVFoundation

struct StandaloneVRView: View {
    @ObservedObject var appState: AppState
    @StateObject private var vrEngine = VREngine()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Dual-Eye 120Hz SCNView Viewport
            DualEyeVRContainer(vrEngine: vrEngine)
                .ignoresSafeArea()
            
            // Dual Centered Crosshairs
            HStack(spacing: 0) {
                Crosshair().frame(maxWidth: .infinity, maxHeight: .infinity)
                Crosshair().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)
        }
        .onAppear {
            vrEngine.onExit = {
                appState.currentMode = .home
            }
            vrEngine.start()
        }
        .onDisappear { vrEngine.stop() }
        .statusBarHidden(true)
    }
}

// MARK: - Dual-Eye SCNView Container (Native High-Perf 120Hz)

class DualEyeContainerView: UIView {
    let leftView: SCNView
    let rightView: SCNView
    
    // Hardware-accelerated GPU passthrough
    private let leftPreview: AVCaptureVideoPreviewLayer
    private let rightPreview: AVCaptureVideoPreviewLayer
    
    init(leftView: SCNView, rightView: SCNView) {
        self.leftView = leftView
        self.rightView = rightView
        
        leftPreview = AVCaptureVideoPreviewLayer(session: PassthroughManager.shared.captureSession)
        leftPreview.videoGravity = .resizeAspectFill
        rightPreview = AVCaptureVideoPreviewLayer(session: PassthroughManager.shared.captureSession)
        rightPreview.videoGravity = .resizeAspectFill
        
        super.init(frame: .zero)
        self.backgroundColor = .black
        
        if let conn = leftPreview.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .landscapeRight
        }
        if let conn = rightPreview.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .landscapeRight
        }
        
        self.layer.addSublayer(leftPreview)
        self.layer.addSublayer(rightPreview)
        self.addSubview(leftView)
        self.addSubview(rightView)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        let halfWidth = bounds.width / 2.0
        let leftF = CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        let rightF = CGRect(x: halfWidth, y: 0, width: halfWidth, height: bounds.height)
        
        leftPreview.frame = leftF
        leftView.frame = leftF
        
        rightPreview.frame = rightF
        rightView.frame = rightF
    }
}

struct DualEyeVRContainer: UIViewRepresentable {
    let vrEngine: VREngine
    
    func makeUIView(context: Context) -> DualEyeContainerView {
        let leftView = SCNView()
        leftView.scene = vrEngine.scene
        leftView.pointOfView = vrEngine.leftCameraNode
        leftView.preferredFramesPerSecond = 120
        leftView.isPlaying = true
        leftView.loops = true
        leftView.backgroundColor = .clear
        leftView.antialiasingMode = .multisampling2X
        
        let rightView = SCNView()
        rightView.scene = vrEngine.scene
        rightView.pointOfView = vrEngine.rightCameraNode
        rightView.preferredFramesPerSecond = 120
        rightView.isPlaying = true
        rightView.loops = true
        rightView.backgroundColor = .clear
        rightView.antialiasingMode = .multisampling2X
        
        let container = DualEyeContainerView(leftView: leftView, rightView: rightView)
        
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        container.addGestureRecognizer(tap)
        
        return container
    }
    
    func updateUIView(_ uiView: DualEyeContainerView, context: Context) {
        uiView.leftView.pointOfView = vrEngine.leftCameraNode
        uiView.rightView.pointOfView = vrEngine.rightCameraNode
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(vrEngine: vrEngine)
    }
    
    class Coordinator: NSObject {
        let vrEngine: VREngine
        init(vrEngine: VREngine) { self.vrEngine = vrEngine }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let loc = gesture.location(in: view)
            let totalW = view.bounds.width
            let isLeft = loc.x < totalW / 2.0
            let size = CGSize(width: totalW / 2.0, height: view.bounds.height)
            let eyeLoc = CGPoint(x: isLeft ? loc.x : loc.x - totalW / 2.0, y: loc.y)
            vrEngine.handleDirectScreenTap(location: eyeLoc, isLeftEye: isLeft, size: size)
        }
    }
}

struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
                .frame(width: 22, height: 22)
            Circle()
                .fill(Color.cyan)
                .frame(width: 5, height: 5)
        }
    }
}

// MARK: - VR Engine

class VREngine: ObservableObject {
    let scene = SCNScene()
    let leftCameraNode  = SCNNode()
    let rightCameraNode = SCNNode()
    
    @Published var monitorScale: CGFloat = 1.0
    var onExit: (() -> Void)?
    
    private let cameraRig   = SCNNode()
    private let motionManager = CMMotionManager()
    
    // Single unified monitor
    private var monitorNode: VRMonitorNode?
    
    private var handCursor: HandCursorNode?
    private var mouseCursor: MouseCursorNode?
    
    private var cancellables = Set<AnyCancellable>()
    
    // Monitor distance in front of user
    private let monitorDistance: Float = -2.0
    
    // IPD in meters (default 65mm)
    private var ipd: Float = 0.065
    
    // Reference attitude for bulletproof zero-calibration
    private var referenceAttitude: CMAttitude?
    
    init() {
        setupScene()
        setupCameras()
        setupHandCursor()
        setupMouseCursor()
        spawnMonitor()
    }
    
    // MARK: - Lifecycle
    
    func start() {
        referenceAttitude = nil
        startHeadTracking()
        startPassthrough()
        startTracking()
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
            scene.background.contents = UIColor.clear
        } else {
            PassthroughManager.shared.stop()
            scene.background.contents = UIColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1.0)
        }
    }
    
    // MARK: - Recalibrate Center View (Sets reference attitude)
    
    func recalibrateView() {
        referenceAttitude = nil
        cameraRig.eulerAngles = SCNVector3(0, 0, 0)
        monitorNode?.position = SCNVector3(0, 0.05, monitorDistance)
        monitorNode?.eulerAngles = SCNVector3(0, 0, 0)
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
        scene.background.contents = UIColor.clear
        
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 1000
        ambient.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambient)
    }
    
    private func setupCameras() {
        cameraRig.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraRig)
        
        let leftCam = SCNCamera()
        leftCam.zNear = 0.01
        leftCam.zFar = 100.0
        leftCam.fieldOfView = 90
        leftCameraNode.camera = leftCam
        leftCameraNode.position = SCNVector3(-ipd / 2.0, 0, 0)
        cameraRig.addChildNode(leftCameraNode)
        
        let rightCam = SCNCamera()
        rightCam.zNear = 0.01
        rightCam.zFar = 100.0
        rightCam.fieldOfView = 90
        rightCameraNode.camera = rightCam
        rightCameraNode.position = SCNVector3(ipd / 2.0, 0, 0)
        cameraRig.addChildNode(rightCameraNode)
    }
    
    // MARK: - Spawn Single Monitor
    
    private func spawnMonitor() {
        let monitor = VRMonitorNode(width: 2.2, height: 1.24)
        
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
        monitor.onExitVRRequested = { [weak self] in
            guard let self = self else { return }
            self.stop()
            DispatchQueue.main.async {
                self.onExit?()
            }
        }
        
        // Position directly in front at eye level (Z = -2.0m)
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
    
    // MARK: - Landscape VR Head Tracking (120Hz Delta Calibration)
    
    private func startHeadTracking() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
        
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: OperationQueue.main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            
            // 1. Capture reference attitude on first frame or upon recalibration
            if self.referenceAttitude == nil {
                self.referenceAttitude = motion.attitude.copy() as? CMAttitude
            }
            
            guard let ref = self.referenceAttitude,
                  let current = motion.attitude.copy() as? CMAttitude else { return }
            
            // 2. Compute delta attitude relative to reference
            // This guarantees that at t=0 or upon Recalibrate, delta rotation is strictly (0, 0, 0)!
            current.multiply(byInverseOf: ref)
            
            // 3. Map delta orientation for Landscape Left:
            // Tilting head up/down = -current.roll
            // Turning head left/right = -current.yaw
            let pitch = Float(-current.roll)
            let yaw   = Float(-current.yaw)
            
            self.cameraRig.eulerAngles = SCNVector3(pitch, yaw, 0)
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
