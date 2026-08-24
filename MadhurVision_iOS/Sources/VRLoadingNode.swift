import SceneKit
import SpriteKit
import UIKit

class VRLoadingNode: SCNNode {
    
    init(width: CGFloat = 2.8, height: CGFloat = 1.6) {
        super.init()
        
        let plane = SCNPlane(width: width, height: height)
        plane.cornerRadius = 0.1
        
        let mat = SCNMaterial()
        
        // SpriteKit Scene for high quality 2D rendering
        let skScene = SKScene(size: CGSize(width: 1400, height: 800))
        skScene.backgroundColor = UIColor(white: 0.05, alpha: 0.5) // 50% transparent dark gray
        
        // Title
        let titleLabel = SKLabelNode(text: "MadhurVision OS")
        titleLabel.fontName = "HelveticaNeue-Bold"
        titleLabel.fontSize = 110
        titleLabel.fontColor = .white
        titleLabel.position = CGPoint(x: 700, y: 450)
        titleLabel.verticalAlignmentMode = .center
        titleLabel.horizontalAlignmentMode = .center
        skScene.addChild(titleLabel)
        
        // Subtitle / Loading text
        let loadLabel = SKLabelNode(text: "Loading system modules...")
        loadLabel.fontName = "HelveticaNeue-Medium"
        loadLabel.fontSize = 50
        loadLabel.fontColor = .cyan
        loadLabel.position = CGPoint(x: 700, y: 320)
        loadLabel.verticalAlignmentMode = .center
        loadLabel.horizontalAlignmentMode = .center
        skScene.addChild(loadLabel)
        
        // Apply SKScene to diffuse (Flip texture to fix upside-down rendering)
        mat.diffuse.contents = skScene
        mat.diffuse.contentsTransform = SCNMatrix4Translate(SCNMatrix4MakeScale(1, -1, 1), 0, 1, 0)
        mat.isDoubleSided = true
        plane.materials = [mat]
        self.geometry = plane
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
