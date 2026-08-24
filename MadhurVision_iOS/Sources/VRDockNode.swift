import SceneKit
import SpriteKit
import UIKit

class VRDockNode: SCNNode {
    
    let browserHitNode = SCNNode()
    let settingsHitNode = SCNNode()
    
    init(height: CGFloat = 1.6) {
        super.init()
        
        let plane = SCNPlane(width: 0.4, height: height)
        plane.cornerRadius = 0.2
        let mat = SCNMaterial()
        
        // SpriteKit Scene for high quality 2D rendering
        let skScene = SKScene(size: CGSize(width: 200, height: 800))
        skScene.backgroundColor = UIColor(white: 0.1, alpha: 0.5) // Glass look
        
        // Browser Icon (Label with Emoji or Text)
        let bIcon = SKLabelNode(text: "🌐")
        bIcon.fontName = "AppleColorEmoji"
        bIcon.fontSize = 80
        bIcon.position = CGPoint(x: 100, y: 550)
        bIcon.verticalAlignmentMode = .center
        bIcon.horizontalAlignmentMode = .center
        skScene.addChild(bIcon)
        
        let bText = SKLabelNode(text: "Browser")
        bText.fontName = "HelveticaNeue-Medium"
        bText.fontSize = 24
        bText.fontColor = .white
        bText.position = CGPoint(x: 100, y: 480)
        bText.verticalAlignmentMode = .center
        bText.horizontalAlignmentMode = .center
        skScene.addChild(bText)
        
        // Settings Icon
        let sIcon = SKLabelNode(text: "⚙️")
        sIcon.fontName = "AppleColorEmoji"
        sIcon.fontSize = 80
        sIcon.position = CGPoint(x: 100, y: 250)
        sIcon.verticalAlignmentMode = .center
        sIcon.horizontalAlignmentMode = .center
        skScene.addChild(sIcon)
        
        let sText = SKLabelNode(text: "Settings")
        sText.fontName = "HelveticaNeue-Medium"
        sText.fontSize = 24
        sText.fontColor = .white
        sText.position = CGPoint(x: 100, y: 180)
        sText.verticalAlignmentMode = .center
        sText.horizontalAlignmentMode = .center
        skScene.addChild(sText)
        
        mat.diffuse.contents = skScene
        mat.diffuse.contentsTransform = SCNMatrix4Translate(SCNMatrix4MakeScale(1, -1, 1), 0, 1, 0)
        mat.isDoubleSided = true
        plane.materials = [mat]
        self.geometry = plane
        
        // Transparent 3D touch targets (so VREngine can detect clicks)
        
        // Browser Hit Target (Top half)
        let bHitPlane = SCNPlane(width: 0.4, height: 0.4)
        bHitPlane.materials.first?.diffuse.contents = UIColor.clear
        browserHitNode.geometry = bHitPlane
        browserHitNode.name = "dock_browser"
        // In 3D space, height is 1.6. Y=0 is center. Top half is Y > 0.
        browserHitNode.position = SCNVector3(0, 0.3, 0.01)
        self.addChildNode(browserHitNode)
        
        // Settings Hit Target (Bottom half)
        let sHitPlane = SCNPlane(width: 0.4, height: 0.4)
        sHitPlane.materials.first?.diffuse.contents = UIColor.clear
        settingsHitNode.geometry = sHitPlane
        settingsHitNode.name = "dock_settings"
        settingsHitNode.position = SCNVector3(0, -0.3, 0.01)
        self.addChildNode(settingsHitNode)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
