import SceneKit
import UIKit

class VRSettingsNode: SCNNode {
    
    init(width: CGFloat = 2.4, height: CGFloat = 1.4) {
        super.init()
        
        let plane = SCNPlane(width: width, height: height)
        plane.cornerRadius = 0.05
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 0.95)
        mat.isDoubleSided = true
        plane.materials = [mat]
        self.geometry = plane
        
        // Title
        let titleText = SCNText(string: "System Settings", extrusionDepth: 0.005)
        titleText.font = UIFont.systemFont(ofSize: 0.15, weight: .bold)
        titleText.firstMaterial?.diffuse.contents = UIColor.white
        let titleNode = SCNNode(geometry: titleText)
        let (tMin, tMax) = titleNode.boundingBox
        titleNode.position = SCNVector3(-(tMax.x - tMin.x)/2, 0.45, 0.01)
        self.addChildNode(titleNode)
        
        // Mock Settings Lines
        let settings = [
            "🔊 Volume: 80%",
            "☀️ Brightness: Auto",
            "🛜 Network: Connected to Matrix",
            "🛠️ Hand Tracking: Aggressive Filter",
            "👁️ IPD Offset: 65mm"
        ]
        
        for (i, setting) in settings.enumerated() {
            let text = SCNText(string: setting, extrusionDepth: 0.005)
            text.font = UIFont.systemFont(ofSize: 0.08, weight: .medium)
            text.firstMaterial?.diffuse.contents = UIColor.lightGray
            let node = SCNNode(geometry: text)
            let (min, max) = node.boundingBox
            node.position = SCNVector3(-(max.x - min.x)/2, 0.15 - Float(i) * 0.18, 0.01)
            self.addChildNode(node)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
