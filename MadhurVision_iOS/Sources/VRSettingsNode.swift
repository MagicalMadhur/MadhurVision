import SceneKit
import SpriteKit
import UIKit

class VRSettingsNode: SCNNode {
    
    init(width: CGFloat = 2.4, height: CGFloat = 1.4) {
        super.init()
        
        let plane = SCNPlane(width: width, height: height)
        plane.cornerRadius = 0.05
        let mat = SCNMaterial()
        
        // SpriteKit Scene for high quality 2D rendering
        let skScene = SKScene(size: CGSize(width: 1200, height: 700))
        skScene.backgroundColor = UIColor(white: 0.1, alpha: 0.95)
        
        // Title
        let titleLabel = SKLabelNode(text: "System Settings")
        titleLabel.fontName = "HelveticaNeue-Bold"
        titleLabel.fontSize = 70
        titleLabel.fontColor = .white
        titleLabel.position = CGPoint(x: 600, y: 550)
        titleLabel.verticalAlignmentMode = .center
        titleLabel.horizontalAlignmentMode = .center
        skScene.addChild(titleLabel)
        
        // Mock Settings Lines
        let settings = [
            "🔊 Volume: 80%",
            "☀️ Brightness: Auto",
            "🛜 Network: Connected to Matrix",
            "🛠️ Hand Tracking: Aggressive Filter",
            "👁️ IPD Offset: 65mm"
        ]
        
        for (i, setting) in settings.enumerated() {
            let label = SKLabelNode(text: setting)
            label.fontName = "HelveticaNeue-Medium"
            label.fontSize = 40
            label.fontColor = .lightGray
            // Start below title, spacing 60 points apart
            label.position = CGPoint(x: 600, y: 400 - (CGFloat(i) * 60))
            label.verticalAlignmentMode = .center
            label.horizontalAlignmentMode = .center
            skScene.addChild(label)
        }
        
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
