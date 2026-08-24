import SceneKit
import UIKit

/// A glowing sphere that follows the user's index finger tip in 3D space,
/// and raycasts against the browser window to drive click/scroll interactions.
class HandCursorNode: SCNNode {

    // Reference to the browser node for hit-testing
    weak var browserNode: VRBrowserNode?

    // The glowing dot
    private let dotNode = SCNNode()

    override init() {
        super.init()
        setupCursor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCursor() {
        // Small glowing sphere
        let sphere = SCNSphere(radius: 0.015)
        let material = SCNMaterial()
        material.diffuse.contents  = UIColor.white
        material.emission.contents = UIColor.cyan  // glow
        material.lightingModel = .constant
        sphere.materials = [material]

        dotNode.geometry = sphere
        dotNode.isHidden = true  // hidden until hand detected
        addChildNode(dotNode)
    }

    private var smoothedFingerPos: CGPoint? = nil

    // MARK: - Update per frame

    /// Called every render frame from VREngine.
    /// `fingerPos` is normalized (0–1) in screen space.
    /// `cameraNode` is the active eye camera for raycasting.
    func update(fingerPos: CGPoint,
                cameraNode: SCNNode,
                scene: SCNScene,
                isPinching: Bool,
                scrollDelta: CGFloat) {

        guard fingerPos != .zero else {
            dotNode.isHidden = true
            smoothedFingerPos = nil
            return
        }

        // Apply strong low-pass filter to eliminate jitter (sniper-level stabilization)
        let target = fingerPos
        if let current = smoothedFingerPos {
            smoothedFingerPos = CGPoint(
                x: current.x + (target.x - current.x) * 0.05,
                y: current.y + (target.y - current.y) * 0.05
            )
        } else {
            smoothedFingerPos = target
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

        // --- Raycast against the browser node ---
        let hits = scene.rootNode.hitTestWithSegment(
            from: worldOrigin,
            to: rayEnd,
            options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue]
        )

        if let hit = hits.first(where: { $0.node === browserNode }) {
            // Cursor is hitting the browser window
            dotNode.isHidden = false
            dotNode.worldPosition = hit.worldCoordinates

            // UV coordinates on the browser texture (0–1)
            let uv = CGPoint(x: CGFloat(hit.textureCoordinates(withMappingChannel: 0).x),
                             y: CGFloat(1.0 - hit.textureCoordinates(withMappingChannel: 0).y))

            if isPinching {
                browserNode?.simulateClick(at: uv)
            }

            if abs(scrollDelta) > 0.005 {
                browserNode?.simulateScroll(by: scrollDelta)
            }

        } else {
            // Cursor not on browser — hide or float in air
            dotNode.isHidden = true
        }
    }
}
