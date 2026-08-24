import SceneKit
import UIKit

/// A high-contrast mouse arrow that follows the user's index finger tip in 3D space,
/// and raycasts against the browser window to drive click/scroll interactions.
class HandCursorNode: SCNNode {

    // The closure to call when a pinch-click occurs
    var onClick: ((SCNHitTestResult) -> Void)?
    var onScroll: ((SCNHitTestResult, CGFloat) -> Void)?

    // The visible pointer
    private let dotNode = SCNNode()

    override init() {
        super.init()
        setupCursor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCursor() {
        let plane = SCNPlane(width: 0.05, height: 0.065)
        let material = SCNMaterial()
        let pointerImage = createPointerImage()
        material.diffuse.contents = pointerImage
        material.transparent.contents = pointerImage
        material.emission.contents = UIColor(white: 1.0, alpha: 0.35)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.materials = [material]

        dotNode.geometry = plane
        // Anchor the arrow tip at the raycast point instead of its centre.
        dotNode.pivot = SCNMatrix4MakeTranslation(-0.025, 0.0325, 0)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        dotNode.constraints = [billboard]
        dotNode.isHidden = true
        addChildNode(dotNode)
    }

    private func createPointerImage() -> UIImage {
        let size = CGSize(width: 128, height: 160)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 12, y: 10))
            path.addLine(to: CGPoint(x: 12, y: 116))
            path.addLine(to: CGPoint(x: 42, y: 86))
            path.addLine(to: CGPoint(x: 67, y: 145))
            path.addLine(to: CGPoint(x: 88, y: 136))
            path.addLine(to: CGPoint(x: 63, y: 77))
            path.addLine(to: CGPoint(x: 112, y: 77))
            path.close()

            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.setStrokeColor(UIColor.black.cgColor)
            context.cgContext.setLineWidth(9)
            context.cgContext.setLineJoin(.round)
            context.cgContext.addPath(path.cgPath)
            context.cgContext.drawPath(using: .fillStroke)
        }
    }

    private var smoothedFingerPos: CGPoint? = nil

    // MARK: - Update per frame

    /// Called every render frame from VREngine.
    /// `fingerPos` is normalized (0–1) in screen space.
    /// `cameraNode` is the active eye camera for raycasting.
    private var previousIsPinching = false

    func update(fingerPos: CGPoint,
                cameraNode: SCNNode,
                scene: SCNScene,
                isPinching: Bool,
                scrollDelta: CGFloat) {

        guard fingerPos != .zero else {
            dotNode.isHidden = true
            smoothedFingerPos = nil
            previousIsPinching = false
            return
        }

        // Extremely aggressive low-pass filter (0.05) to eliminate all jitter
        if smoothedFingerPos == nil {
            smoothedFingerPos = fingerPos
        } else {
            let alpha: CGFloat = 0.05
            let current = smoothedFingerPos!
            smoothedFingerPos = CGPoint(
                x: current.x + (fingerPos.x - current.x) * alpha,
                y: current.y + (fingerPos.y - current.y) * alpha
            )
        }
        let pos = smoothedFingerPos!

        // Apply sensitivity multiplier so the user doesn't have to move their hand out of the camera's narrow FOV
        let sensitivity: Float = 2.5
        let ndcX = Float(pos.x * 2.0 - 1.0) * sensitivity
        let ndcY = -Float(pos.y * 2.0 - 1.0) * sensitivity // INVERT Y-AXIS HERE

        // Build a ray in camera space (pointing into the scene, at distance 3m)
        let rayDirection = SCNVector3(ndcX * 1.5, ndcY * 1.5, -3.0)

        // Transform to world space
        let worldOrigin    = cameraNode.worldPosition
        let worldDirection = cameraNode.convertVector(rayDirection, to: nil)

        let rayEnd = SCNVector3(
            worldOrigin.x + worldDirection.x,
            worldOrigin.y + worldDirection.y,
            worldOrigin.z + worldDirection.z
        )

        // --- Generic Raycast ---
        let hits = scene.rootNode.hitTestWithSegment(
            from: worldOrigin,
            to: rayEnd,
            options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue]
        )

        // Find the first hit that isn't the cursor itself
        if let hit = hits.first(where: { $0.node !== self && $0.node !== dotNode }) {
            // Cursor is hitting an object in the world
            dotNode.isHidden = false
            let normal = hit.node.convertVector(hit.localNormal, to: nil)
            dotNode.worldPosition = SCNVector3(
                hit.worldCoordinates.x + normal.x * 0.008,
                hit.worldCoordinates.y + normal.y * 0.008,
                hit.worldCoordinates.z + normal.z * 0.008
            )
            
            // Only fire click once per pinch (rising edge trigger)
            if isPinching && !previousIsPinching {
                onClick?(hit)
            }
            
            // The engine validates the target and forwards the WebKit call to
            // the main thread. This renderer never performs UIKit work itself.
            if scrollDelta != 0 {
                onScroll?(hit, scrollDelta)
            }
        } else {
            // Keep the arrow visible even when the ray misses the panel. This
            // makes it clear that index tracking is active; it simply cannot
            // click until the arrow reaches an interactive surface.
            dotNode.isHidden = false
            dotNode.worldPosition = rayEnd
        }
        
        previousIsPinching = isPinching
    }
}
