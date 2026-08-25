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
    
    // Camera feed is rendered INSIDE SceneKit via scene.background.contents,
    // not as a separate CALayer behind the SCNViews. CAMetalLayer (used by
    // SCNView) cannot alpha-composite with layers behind it during live GPU
    // rendering — that's why preview layers appeared black on-screen but
    // showed correctly in screenshots.
    
    init(leftView: SCNView, rightView: SCNView) {
        self.leftView = leftView
        self.rightView = rightView
        
        super.init(frame: .zero)
        self.backgroundColor = .black
        
        self.addSubview(leftView)
        self.addSubview(rightView)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        let orientation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation ?? .landscapeRight
        let avOrientation: AVCaptureVideoOrientation = (orientation == .landscapeLeft) ? .landscapeLeft : .landscapeRight
        PassthroughManager.shared.updateOrientation(avOrientation)
        
        let halfWidth = bounds.width / 2.0
        leftView.frame = CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        rightView.frame = CGRect(x: halfWidth, y: 0, width: halfWidth, height: bounds.height)
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
        leftView.rendersContinuously = true
        leftView.loops = true
        leftView.delegate = vrEngine
        leftView.backgroundColor = .clear
        leftView.isOpaque = false
        leftView.layer.isOpaque = false
        leftView.antialiasingMode = .multisampling2X
        
        let rightView = SCNView()
        rightView.scene = vrEngine.scene
        rightView.pointOfView = vrEngine.rightCameraNode
        rightView.preferredFramesPerSecond = 120
        rightView.isPlaying = true
        rightView.rendersContinuously = true
        rightView.loops = true
        rightView.delegate = vrEngine
        rightView.backgroundColor = .clear
        rightView.isOpaque = false
        rightView.layer.isOpaque = false
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

class VREngine: NSObject, ObservableObject, SCNSceneRendererDelegate {
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

    /// Data from UIKit, Vision, Core Motion, and WebKit is only written here.
    /// SceneKit nodes are touched exclusively from renderer(_:updateAtTime:).
    private struct PendingSceneInput {
        var hand: HandTrackingInput?
        var mouse: MouseTrackingInput?
        var controller: ControllerMotionInput?
        var headRotation: SCNVector3?
        var monitorScale: Float?
        var ipd: Float?
        var shouldRecalibrate = false
        var passthroughBackground: UIColor?
        var directTap: DirectTap?
        var monitorImage: UIImage?
        var resetMonitor = false

        var hasWork: Bool {
            hand != nil || mouse != nil || controller != nil || headRotation != nil || monitorScale != nil ||
            ipd != nil || shouldRecalibrate || passthroughBackground != nil ||
            directTap != nil || monitorImage != nil || resetMonitor
        }
    }

    private struct MouseTrackingInput {
        let position: CGPoint
        let isClicking: Bool
        let isActive: Bool
    }

    private struct DirectTap {
        let ndcX: Float
        let ndcY: Float
        let isLeftEye: Bool
    }

    private let pendingInputLock = NSLock()
    private var pendingInput = PendingSceneInput()
    private let sceneUpdateLock = NSLock()
    
    // Monitor distance in front of user
    private let monitorDistance: Float = -2.0
    
    // IPD in meters (default 65mm)
    private var ipd: Float = 0.065
    
    // Reference attitude for bulletproof zero-calibration
    private var referenceAttitude: CMAttitude?
    
    override init() {
        super.init()
        setupScene()
        setupCameras()
        setupHandCursor()
        setupMouseCursor()
        spawnMonitor()
    }
    
    // MARK: - Lifecycle
    
    func start() {
        AppLogger.shared.log("[VREngine] Starting VR Engine...")
        referenceAttitude = nil
        startHeadTracking()
        startPassthrough()
        startTracking()
        AppLogger.shared.log("[VREngine] VR Engine started successfully")
    }
    
    func stop() {
        AppLogger.shared.log("[VREngine] Stopping VR Engine...")
        motionManager.stopDeviceMotionUpdates()
        monitorNode?.cleanup()
        PassthroughManager.shared.stop()
        HandTrackingManager.shared.stop()
        AirMouseServer.shared.stop()
        cancellables.removeAll()

        pendingInputLock.lock()
        pendingInput = PendingSceneInput()
        pendingInputLock.unlock()
    }
    
    // MARK: - Scale & Settings
    
    func scaleMonitor(by delta: CGFloat) {
        setMonitorScale(monitorScale + delta)
    }
    
    func setMonitorScale(_ newScale: CGFloat) {
        monitorScale = max(0.4, min(2.8, newScale))
        let s = Float(monitorScale)
        enqueueSceneInput { $0.monitorScale = s }
    }
    
    func setIPD(_ newIPD: Float) {
        ipd = max(0.050, min(0.080, newIPD))
        enqueueSceneInput { $0.ipd = ipd }
    }
    
    func setPassthrough(enabled: Bool) {
        AppLogger.shared.log("[VREngine] Passthrough toggled: \(enabled)")
        if enabled {
            PassthroughManager.shared.start(scene: scene)
        } else {
            PassthroughManager.shared.stop()
            enqueueSceneInput {
                $0.passthroughBackground = UIColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1.0)
            }
        }
    }
    
    // MARK: - Recalibrate Center View (Sets reference attitude)
    
    func recalibrateView() {
        referenceAttitude = nil
        enqueueSceneInput { $0.shouldRecalibrate = true }
    }
    
    // MARK: - Direct Screen Taps (Fallback)
    
    func handleDirectScreenTap(location: CGPoint, isLeftEye: Bool, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let tap = DirectTap(
            ndcX: Float(location.x / size.width) * 2.0 - 1.0,
            ndcY: -(Float(location.y / size.height) * 2.0 - 1.0),
            isLeftEye: isLeftEye
        )
        enqueueSceneInput { $0.directTap = tap }
    }
    
    private func handleHit(_ hit: SCNHitTestResult) {
        let node = hit.node
        if let monitor = monitorNode,
           node === monitor || node.parent === monitor || node.name == "monitor_border" {
            let uv = monitor.uvCoordinates(fromWorldPoint: hit.worldCoordinates)
            AppLogger.shared.log("[VREngine] Laser Click registered at UV: (\(String(format: "%.3f", uv.x)), \(String(format: "%.3f", uv.y))) on node: \(node.name ?? "unnamed")")
            DispatchQueue.main.async { [weak monitor] in
                monitor?.simulateClick(at: uv)
            }
        }
    }

    private func handleScroll(_ hit: SCNHitTestResult, delta: CGFloat) {
        guard delta != 0 else { return }
        let node = hit.node
        guard let monitor = monitorNode,
              node === monitor || node.parent === monitor || node.name == "monitor_border" else { return }

        DispatchQueue.main.async { [weak monitor] in
            monitor?.simulateScroll(by: delta)
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
        monitor.onSnapshotImage = { [weak self] image in
            self?.enqueueSceneInput { $0.monitorImage = image }
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
        cursor.onScroll = { [weak self] hit, delta in
            self?.handleScroll(hit, delta: delta)
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
            
            self.enqueueSceneInput { $0.headRotation = SCNVector3(pitch, yaw, 0) }
        }
    }
    
    // MARK: - Passthrough Camera
    
    private func startPassthrough() {
        PassthroughManager.shared.start(scene: scene)
    }
    
    // Grab State
    private var isCurrentlyGrabbing = false
    private var grabOffset: SCNVector3 = SCNVector3Zero
    private var grabStartPalmSpan: CGFloat = 0
    private var grabStartDistance: Float = 2.0
    
    // MARK: - Tracking & Gestures
    
    private func startTracking() {
        HandTrackingManager.shared.start()
        MouseTrackingManager.shared.start()
        AirMouseServer.shared.start()
        
        let ht = HandTrackingManager.shared
        let mt = MouseTrackingManager.shared
        
        AirMouseServer.shared.onControllerInput = { [weak self] input in
            self?.enqueueSceneInput {
                $0.controller = input
                if input.resetRequested {
                    $0.resetMonitor = true
                }
            }
        }
        
        // Publishers only enqueue value data. They never read or mutate a
        // SceneKit node because the two eye renderers can be active here.
        mt.$virtualPosition
            .combineLatest(mt.$isLeftClicking, mt.$isMouseActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] (pos, isClicking, isActive) in
                self?.enqueueSceneInput {
                    $0.mouse = MouseTrackingInput(
                        position: pos,
                        isClicking: isClicking,
                        isActive: isActive
                    )
                }
            }
            .store(in: &cancellables)
        
        // HandTrackingInput is emitted once per Vision result, so gesture
        // fields cannot be sampled halfway through a publish cycle.
        ht.$latestInput
            .receive(on: RunLoop.main)
            .sink { [weak self] input in
                self?.enqueueSceneInput {
                    $0.hand = input
                    $0.resetMonitor = $0.resetMonitor || input.resetRequested
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - SceneKit Render Loop

    // State latched for 120Hz continuous evaluation
    private var latestHandInput: HandTrackingInput?
    private var latestMouseInput: MouseTrackingInput?
    private var latestControllerInput: ControllerMotionInput?

    /// Both eyes can call this, but a lock ensures one render callback at a
    /// time consumes and applies the queued scene work.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        sceneUpdateLock.lock()
        defer { sceneUpdateLock.unlock() }

        let input = takePendingSceneInput()
        
        if let h = input.hand { latestHandInput = h }
        if let m = input.mouse { latestMouseInput = m }
        if let c = input.controller { latestControllerInput = c }

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }

        if input.shouldRecalibrate {
            cameraRig.eulerAngles = SCNVector3Zero
            monitorNode?.position = SCNVector3(0, 0.05, monitorDistance)
            monitorNode?.eulerAngles = SCNVector3Zero
            isCurrentlyGrabbing = false
        }

        if let rotation = input.headRotation {
            cameraRig.eulerAngles = rotation
        }

        if let ipd = input.ipd {
            leftCameraNode.position = SCNVector3(-ipd / 2.0, 0, 0)
            rightCameraNode.position = SCNVector3(ipd / 2.0, 0, 0)
        }

        if let scale = input.monitorScale {
            monitorNode?.scale = SCNVector3(scale, scale, scale)
        }

        if let background = input.passthroughBackground {
            scene.background.contents = background
        }

        if let image = input.monitorImage {
            monitorNode?.applySnapshot(image)
        }

        if let tap = input.directTap {
            applyDirectScreenTap(tap)
        }

        if input.resetMonitor {
            resetMonitorToHome()
        } else if AirMouseServer.shared.isControllerActive, let controller = latestControllerInput {
            // Wireless Air Controller is actively transmitting (Priority Mode)
            applyControllerInput(controller)
        } else if let hand = latestHandInput {
            // Automatic Fallback to Apple Vision Camera Hand Tracking
            applyHandInput(hand)
        }

        if let mouse = latestMouseInput, mouse.isActive {
            mouseCursor?.update(
                virtualPosition: mouse.position,
                cameraNode: leftCameraNode,
                scene: scene,
                isClicking: mouse.isClicking
            )
        }
    }

    private func enqueueSceneInput(_ update: (inout PendingSceneInput) -> Void) {
        pendingInputLock.lock()
        update(&pendingInput)
        pendingInputLock.unlock()
    }

    private func takePendingSceneInput() -> PendingSceneInput {
        pendingInputLock.lock()
        let input = pendingInput
        pendingInput = PendingSceneInput()
        pendingInputLock.unlock()
        return input
    }

    private func applyDirectScreenTap(_ tap: DirectTap) {
        let cameraNode = tap.isLeftEye ? leftCameraNode : rightCameraNode
        let rayDirection = SCNVector3(tap.ndcX * 1.5, tap.ndcY * 1.5, -3.0)
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

    private func applyHandInput(_ input: HandTrackingInput) {
        if input.isGrabbing, let monitor = monitorNode {
            let sensitivity: Float = 2.5
            let ndcX = Float(input.grabPosition.x * 2.0 - 1.0) * sensitivity
            let ndcY = Float(input.grabPosition.y * 2.0 - 1.0) * sensitivity

            let isNewGrab = !isCurrentlyGrabbing
            if isNewGrab {
                isCurrentlyGrabbing = true
                grabStartPalmSpan = max(input.palmSpan, 0.001)
                let monitorInCameraSpace = leftCameraNode.convertPosition(monitor.worldPosition, from: nil)
                grabStartDistance = max(-monitorInCameraSpace.z, 0.6)
            }

            // A larger apparent palm means the fist is closer to the camera.
            // Move the panel forward/backward like a projector rather than
            // scaling it, so its physical proportions and orientation remain stable.
            let depthRatio = Float(grabStartPalmSpan / max(input.palmSpan, 0.001))
            let targetDistance = min(max(grabStartDistance * depthRatio, 0.6), 4.5)
            let localPoint = SCNVector3(ndcX * 2.5, -ndcY * 2.5, -targetDistance)
            let worldPoint = leftCameraNode.convertPosition(localPoint, to: nil)

            if isNewGrab {
                grabOffset = SCNVector3(
                    monitor.position.x - worldPoint.x,
                    monitor.position.y - worldPoint.y,
                    monitor.position.z - worldPoint.z
                )
            }

            let target = SCNVector3(
                worldPoint.x + grabOffset.x,
                worldPoint.y + grabOffset.y,
                worldPoint.z + grabOffset.z
            )
            monitor.position.x += (target.x - monitor.position.x) * 0.15
            monitor.position.y += (target.y - monitor.position.y) * 0.15
            monitor.position.z += (target.z - monitor.position.z) * 0.15
            return
        }

        isCurrentlyGrabbing = false
        grabOffset = SCNVector3Zero
        handCursor?.update(
            fingerPos: input.indexTipPosition,
            cameraNode: leftCameraNode,
            scene: scene,
            isPinching: input.isPinching,
            scrollDelta: input.scrollDelta
        )
    }

    private func applyControllerInput(_ input: ControllerMotionInput) {
        isCurrentlyGrabbing = false
        grabOffset = SCNVector3Zero

        // Map controller (yaw, pitch) directly to normalized screen coordinate space
        let screenX = CGFloat(input.yaw * 0.5 + 0.5)
        let screenY = CGFloat(input.pitch * 0.5 + 0.5)
        let fingerPos = CGPoint(
            x: max(0.0, min(1.0, screenX)),
            y: max(0.0, min(1.0, screenY))
        )

        handCursor?.update(
            fingerPos: fingerPos,
            cameraNode: leftCameraNode,
            scene: scene,
            isPinching: input.isClicking,
            scrollDelta: CGFloat(input.scrollDelta)
        )
    }

    private func resetMonitorToHome() {
        guard let monitor = monitorNode else { return }

        // Anchor the default panel in front of the user's current gaze, while
        // keeping it upright rather than inheriting head pitch or roll.
        let homeInHeadSpace = SCNVector3(0, 0.05, monitorDistance)
        monitor.worldPosition = cameraRig.convertPosition(homeInHeadSpace, to: nil)
        monitor.eulerAngles = SCNVector3(0, cameraRig.eulerAngles.y, 0)
        monitor.scale = SCNVector3(1, 1, 1)

        isCurrentlyGrabbing = false
        grabOffset = SCNVector3Zero
        grabStartPalmSpan = 0
        grabStartDistance = -monitorDistance

        // WebKit and ObservableObject changes belong to the main thread.
        DispatchQueue.main.async { [weak self, weak monitor] in
            self?.monitorScale = 1.0
            monitor?.goHome()
        }
    }
}
