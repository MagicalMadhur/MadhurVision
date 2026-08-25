import SceneKit
import UIKit
import simd

/// Meta Quest-style 3D Spatial Laser Pointer
/// - Projects a glowing electric-cyan 3D laser beam from the user's hand into VR space.
/// - Renders an interactive target reticle ring at the exact surface intersection point.
/// - Flashes tactile electric pulses on click with pinpoint accuracy.
class HandCursorNode: SCNNode {

    // Callbacks for VR engine
    var onClick: ((SCNHitTestResult) -> Void)?
    var onScroll: ((SCNHitTestResult, CGFloat) -> Void)?

    // 3D Laser Beam Node
    private let laserNode = SCNNode()
    private let laserCylinder = SCNCylinder(radius: 0.0028, height: 1.0)
    private let laserMaterial = SCNMaterial()

    // 3D Target Reticle Ring
    private let reticleNode = SCNNode()
    private let ringMaterial = SCNMaterial()

    override init() {
        super.init()
        setupLaserBeam()
        setupReticle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup Geometry

    private func setupLaserBeam() {
        laserCylinder.radialSegmentCount = 12
        laserCylinder.heightSegmentCount = 1
        laserCylinder.height = 1.0
        
        laserMaterial.diffuse.contents = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.85)
        laserMaterial.emission.contents = UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0)
        laserMaterial.lightingModel = .constant
        laserMaterial.isDoubleSided = true
        laserMaterial.blendMode = .add
        laserMaterial.readsFromDepthBuffer = false
        laserMaterial.writesToDepthBuffer = false
        laserCylinder.materials = [laserMaterial]

        laserNode.geometry = laserCylinder
        // Pivot at bottom base (y = -0.5) so scaling height scales forward along ray
        laserNode.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0)
        laserNode.isHidden = true
        addChildNode(laserNode)
    }

    private func setupReticle() {
        // Outer Target Ring
        let ringPlane = SCNPlane(width: 0.045, height: 0.045)
        let ringImage = createReticleImage()
        ringMaterial.diffuse.contents = ringImage
        ringMaterial.transparent.contents = ringImage
        ringMaterial.emission.contents = UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.8)
        ringMaterial.lightingModel = .constant
        ringMaterial.isDoubleSided = true
        ringMaterial.readsFromDepthBuffer = false
        ringMaterial.writesToDepthBuffer = false
        ringPlane.materials = [ringMaterial]

        reticleNode.geometry = ringPlane
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        reticleNode.constraints = [billboard]
        reticleNode.isHidden = true
        addChildNode(reticleNode)
    }

    private func createReticleImage() -> UIImage {
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let center = CGPoint(x: 64, y: 64)
            
            // Outer glow shadow
            context.cgContext.saveGState()
            context.cgContext.setShadow(offset: .zero, blur: 12, color: UIColor(red: 0, green: 0.83, blue: 1.0, alpha: 0.9).cgColor)
            
            // Outer Ring
            let ringPath = UIBezierPath(arcCenter: center, radius: 46, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            ringPath.lineWidth = 6
            UIColor.white.setStroke()
            ringPath.stroke()
            
            // Dark Outline for outer ring (visible against white backgrounds)
            let darkRing = UIBezierPath(arcCenter: center, radius: 49, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            darkRing.lineWidth = 2
            UIColor.black.setStroke()
            darkRing.stroke()

            // Center Focal Dot
            let dotPath = UIBezierPath(arcCenter: center, radius: 10, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor.white.setFill()
            dotPath.fill()
            
            let dotBorder = UIBezierPath(arcCenter: center, radius: 11, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            dotBorder.lineWidth = 2
            UIColor.black.setStroke()
            dotBorder.stroke()
            
            context.cgContext.restoreGState()
        }
    }

    // MARK: - Update per frame

    private let oneEuroFilter = OneEuroFilter2D(minCutoff: 1.0, beta: 0.008, dCutoff: 1.0)
    private var previousIsPinching = false

    func update(fingerPos: CGPoint,
                cameraNode: SCNNode,
                scene: SCNScene,
                isPinching: Bool,
                scrollDelta: CGFloat) {

        guard fingerPos != .zero else {
            laserNode.isHidden = true
            reticleNode.isHidden = true
            oneEuroFilter.reset()
            previousIsPinching = false
            return
        }

        // Apply adaptive 1€ Filter (Zero jitter when resting, 0ms lag when moving)
        let pos = oneEuroFilter.filter(point: fingerPos)

        // Map 2D camera coordinates with 1:1 natural angular FOV
        let ndcX = Float(pos.x * 2.0 - 1.0)
        let ndcY = -Float(pos.y * 2.0 - 1.0) // Invert Y

        // 1. Stable Hand Origin in 3D Camera Space (anchored in front of user's chest/hand)
        let localHandPos = SCNVector3(ndcX * 0.14 + 0.05, ndcY * 0.14 - 0.18, -0.38)
        let worldHandPos = cameraNode.convertPosition(localHandPos, to: nil)

        // 2. 1:1 Natural Ray Direction pointing directly into the VR monitor plane
        let localTargetPos = SCNVector3(ndcX * 1.15, ndcY * 0.90, -2.1)
        let worldTargetPos = cameraNode.convertPosition(localTargetPos, to: nil)

        // Segment endpoints
        let rayStart = worldHandPos
        let rayEnd   = worldTargetPos

        // 3. Raycast against SceneKit world
        let hits = scene.rootNode.hitTestWithSegment(
            from: rayStart,
            to: rayEnd,
            options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue]
        )

        let targetEndPoint: SCNVector3
        // Find intersection with the interactive monitor
        if let hit = hits.first(where: { $0.node !== self && $0.node !== laserNode && $0.node !== reticleNode }) {
            let hitPoint = hit.worldCoordinates
            let normal = hit.node.convertVector(hit.localNormal, to: nil)

            // Show and position reticle ring hugging surface
            reticleNode.isHidden = false
            reticleNode.worldPosition = SCNVector3(
                hitPoint.x + normal.x * 0.006,
                hitPoint.y + normal.y * 0.006,
                hitPoint.z + normal.z * 0.006
            )
            targetEndPoint = hitPoint

            // Fire click on rising edge
            if isPinching && !previousIsPinching {
                onClick?(hit)
                animateClick()
            }

            // Forward scrolling
            if scrollDelta != 0 {
                onScroll?(hit, scrollDelta)
            }
        } else {
            // When laser moves past monitor edges, project to monitor depth plane (-2.0m)
            // so beam length never jumps or glitches abruptly!
            reticleNode.isHidden = true
            targetEndPoint = cameraNode.convertPosition(SCNVector3(ndcX * 1.5, ndcY * 1.5, -2.0), to: nil)
        }

        positionLaserBeam(from: rayStart, to: targetEndPoint)
        previousIsPinching = isPinching
    }

    // MARK: - 3D Laser Beam Alignment (Zero-Allocation GPU Matrix Transform)

    private func positionLaserBeam(from start: SCNVector3, to end: SCNVector3) {
        laserNode.isHidden = false

        let p1 = simd_float3(start.x, start.y, start.z)
        let p2 = simd_float3(end.x, end.y, end.z)
        let delta = p2 - p1
        let distance = simd_length(delta)

        guard distance > 0.02 else {
            laserNode.isHidden = true
            return
        }

        // 1. Position laser at start (hand anchor)
        laserNode.simdPosition = p1

        // 2. Scale height by distance (pivot is at base y = -0.5)
        laserNode.simdScale = simd_float3(1.0, distance, 1.0)

        // 3. Orient towards delta vector
        let dir = simd_normalize(delta)
        let yAxis = simd_float3(0, 1, 0)
        let quat = simd_quatf(from: yAxis, to: dir)
        laserNode.simdOrientation = quat
    }

    // MARK: - Click Animation (Electric Flash & Pop)

    private func animateClick() {
        // Flash laser beam
        let laserFlash = SCNAction.sequence([
            SCNAction.customAction(duration: 0.08) { [weak self] _, _ in
                self?.laserMaterial.emission.contents = UIColor.white
                self?.laserCylinder.radius = 0.006
            },
            SCNAction.customAction(duration: 0.12) { [weak self] _, _ in
                self?.laserMaterial.emission.contents = UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0)
                self?.laserCylinder.radius = 0.0028
            }
        ])
        laserNode.runAction(laserFlash)

        // Pulse reticle ring
        let reticlePop = SCNAction.sequence([
            SCNAction.scale(to: 0.6, duration: 0.06),
            SCNAction.scale(to: 1.3, duration: 0.08),
            SCNAction.scale(to: 1.0, duration: 0.08)
        ])
        reticleNode.runAction(reticlePop)
    }
}
