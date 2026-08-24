import SceneKit
import UIKit

/// A Windows-like mouse cursor node in 3D space
class MouseCursorNode: SCNNode {
    
    var onClick: ((SCNHitTestResult) -> Void)?
    private var previousIsClicking = false
    
    private let pointerNode = SCNNode()
    
    override init() {
        super.init()
        setupCursor()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupCursor() {
        // Create a 2D plane for the mouse pointer image
        // 0.04m is about 4cm wide
        let plane = SCNPlane(width: 0.03, height: 0.03)
        let material = SCNMaterial()
        material.diffuse.contents = createPointerImage()
        material.isDoubleSided = true
        
        // Ensure transparent parts of the image are invisible
        material.transparent.contents = createPointerImage()
        
        plane.materials = [material]
        
        pointerNode.geometry = plane
        pointerNode.isHidden = true
        
        // Pivot the node so the top-left of the image is the actual interaction point (0,0)
        // By default, SCNPlane is centered.
        // We shift the pivot to the top-left corner.
        pointerNode.pivot = SCNMatrix4MakeTranslation(-0.015, 0.015, 0)
        
        addChildNode(pointerNode)
    }
    
    // Programmatically draws a classic Windows-style mouse cursor
    private func createPointerImage() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        let ctx = UIGraphicsGetCurrentContext()!
        
        // Draw arrow pointing top-left
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 2, y: 2))
        path.addLine(to: CGPoint(x: 2, y: 44))
        path.addLine(to: CGPoint(x: 14, y: 34))
        path.addLine(to: CGPoint(x: 24, y: 56))
        path.addLine(to: CGPoint(x: 32, y: 52))
        path.addLine(to: CGPoint(x: 22, y: 30))
        path.addLine(to: CGPoint(x: 38, y: 30))
        path.close()
        
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(2.0)
        
        ctx.addPath(path.cgPath)
        ctx.drawPath(using: .fillStroke)
        
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return img
    }
    
    func update(virtualPosition: CGPoint,
                cameraNode: SCNNode,
                scene: SCNScene,
                isClicking: Bool) {
        
        // Convert normalized mouse position to a 3D ray
        let ndcX = Float(virtualPosition.x * 2.0 - 1.0)
        let ndcY = -Float(virtualPosition.y * 2.0 - 1.0)
        
        // Same raycast logic as hand cursor
        let rayDirection = SCNVector3(ndcX * 1.5, ndcY * 1.5, -3.0)
        
        let worldOrigin = cameraNode.worldPosition
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
        if let hit = hits.first(where: { $0.node !== self && $0.node !== pointerNode }) {
            pointerNode.isHidden = false
            pointerNode.worldPosition = hit.worldCoordinates
            
            // Adjust depth slightly to float above the surface
            let surfaceNormal = hit.localNormal
            let normalInWorld = hit.node.convertVector(surfaceNormal, to: nil)
            pointerNode.worldPosition = SCNVector3(
                hit.worldCoordinates.x + normalInWorld.x * 0.005,
                hit.worldCoordinates.y + normalInWorld.y * 0.005,
                hit.worldCoordinates.z + normalInWorld.z * 0.005
            )
            
            if isClicking && !previousIsClicking {
                onClick?(hit)
            }
        } else {
            pointerNode.isHidden = true
        }
        
        previousIsClicking = isClicking
    }
}
