import SceneKit
import UIKit

class VRDockNode: SCNNode {
    
    // We store references so we can identify clicks
    let browserIconNode = SCNNode()
    let settingsIconNode = SCNNode()
    
    init(height: CGFloat = 1.6) {
        super.init()
        
        let plane = SCNPlane(width: 0.4, height: height)
        plane.cornerRadius = 0.2
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.white.withAlphaComponent(0.15) // Glass look
        mat.isDoubleSided = true
        plane.materials = [mat]
        self.geometry = plane
        
        // Browser Icon (Globe Emoji)
        let browserText = SCNText(string: "🌐", extrusionDepth: 0.01)
        browserText.font = UIFont.systemFont(ofSize: 0.15)
        browserText.flatness = 0.01
        browserIconNode.geometry = browserText
        browserIconNode.name = "dock_browser"
        let (bMin, bMax) = browserIconNode.boundingBox
        browserIconNode.position = SCNVector3(-(bMax.x - bMin.x)/2, 0.2, 0.02)
        
        // Transparent touch target for browser (easier to hit than complex text geometry)
        let bHitPlane = SCNPlane(width: 0.25, height: 0.25)
        bHitPlane.materials.first?.diffuse.contents = UIColor.clear
        let bHitNode = SCNNode(geometry: bHitPlane)
        bHitNode.name = "dock_browser"
        bHitNode.position = SCNVector3((bMax.x - bMin.x)/2, (bMax.y - bMin.y)/2, 0.01)
        browserIconNode.addChildNode(bHitNode)
        
        self.addChildNode(browserIconNode)
        
        // Settings Icon (Gear Emoji)
        let settingsText = SCNText(string: "⚙️", extrusionDepth: 0.01)
        settingsText.font = UIFont.systemFont(ofSize: 0.15)
        settingsText.flatness = 0.01
        settingsIconNode.geometry = settingsText
        settingsIconNode.name = "dock_settings"
        let (sMin, sMax) = settingsIconNode.boundingBox
        settingsIconNode.position = SCNVector3(-(sMax.x - sMin.x)/2, -0.2, 0.02)
        
        let sHitPlane = SCNPlane(width: 0.25, height: 0.25)
        sHitPlane.materials.first?.diffuse.contents = UIColor.clear
        let sHitNode = SCNNode(geometry: sHitPlane)
        sHitNode.name = "dock_settings"
        sHitNode.position = SCNVector3((sMax.x - sMin.x)/2, (sMax.y - sMin.y)/2, 0.01)
        settingsIconNode.addChildNode(sHitNode)
        
        self.addChildNode(settingsIconNode)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
