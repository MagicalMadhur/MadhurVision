import SceneKit
import UIKit

class VRLoadingNode: SCNNode {
    
    init(width: CGFloat = 2.8, height: CGFloat = 1.6) {
        super.init()
        
        let plane = SCNPlane(width: width, height: height)
        plane.cornerRadius = 0.1
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.black.withAlphaComponent(0.6)
        mat.isDoubleSided = true
        plane.materials = [mat]
        self.geometry = plane
        
        // Title Text
        let titleText = SCNText(string: "MadhurVision OS", extrusionDepth: 0.01)
        titleText.font = UIFont.systemFont(ofSize: 0.2, weight: .bold)
        titleText.firstMaterial?.diffuse.contents = UIColor.white
        titleText.flatness = 0.01
        
        let titleNode = SCNNode(geometry: titleText)
        let (min, max) = titleNode.boundingBox
        let titleWidth = max.x - min.x
        titleNode.position = SCNVector3(-titleWidth/2, 0.1, 0.01)
        self.addChildNode(titleNode)
        
        // Loading Text
        let loadText = SCNText(string: "Loading system modules...", extrusionDepth: 0.005)
        loadText.font = UIFont.systemFont(ofSize: 0.08, weight: .regular)
        loadText.firstMaterial?.diffuse.contents = UIColor.cyan
        loadText.flatness = 0.01
        
        let loadNode = SCNNode(geometry: loadText)
        let (lMin, lMax) = loadNode.boundingBox
        let loadWidth = lMax.x - lMin.x
        loadNode.position = SCNVector3(-loadWidth/2, -0.15, 0.01)
        self.addChildNode(loadNode)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
