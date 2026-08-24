import SceneKit
import WebKit
import UIKit

class VRBrowserNode: SCNNode {
    private var webView: WKWebView!
    
    init(url: URL, width: CGFloat, height: CGFloat) {
        super.init()
        
        // 1. Create the physical 3D plane
        let plane = SCNPlane(width: width, height: height)
        plane.cornerRadius = 0.05  // Rounded corners like a real floating panel
        self.geometry = plane
        
        // Add a glowing border frame around the browser (Meta Quest-style panel border)
        addBorderFrame(width: width, height: height)
        
        // 2. Initialize the Web View
        // We use a high resolution mapping. The aspect ratio must match the plane.
        // If plane is 2.5 x 1.4, let's use a 16:9 1080p resolution for the web view.
        let resolutionMultiplier: CGFloat = 800
        let webWidth = width * resolutionMultiplier
        let webHeight = height * resolutionMultiplier
        
        let webConfig = WKWebViewConfiguration()
        webConfig.allowsInlineMediaPlayback = true
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: webWidth, height: webHeight), configuration: webConfig)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        
        // 3. Map the WebView's CoreAnimation Layer to the SceneKit Material
        let material = SCNMaterial()
        material.diffuse.contents = webView
        material.isDoubleSided = true
        
        // Ensure lighting doesn't wash out the screen
        material.lightingModel = .constant
        
        plane.materials = [material]
        
        // 4. Load the page
        let request = URLRequest(url: url)
        webView.load(request)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func cleanup() {
        webView.stopLoading()
        webView = nil
    }
    
    // In Phase 2, this function will be called by a raycast hit to simulate a click
    func simulateClick(at uv: CGPoint) {
        let x = uv.x * webView.bounds.width
        let y = uv.y * webView.bounds.height
        
        // Inject JS to click at coordinate
        let js = """
            var element = document.elementFromPoint(\(x), \(y));
            if(element) {
                element.click();
            }
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    // Scroll the browser page by a normalized delta (-1 to 1)
    func simulateScroll(by delta: CGFloat) {
        let pixels = delta * 800  // scale to pixels
        let js = "window.scrollBy(0, \(pixels));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    // MARK: - Visual Polish
    
    private func addBorderFrame(width: CGFloat, height: CGFloat) {
        // Thin border plane slightly behind the main browser plane
        let borderPlane = SCNPlane(width: width + 0.04, height: height + 0.04)
        borderPlane.cornerRadius = 0.06
        
        let borderMaterial = SCNMaterial()
        borderMaterial.diffuse.contents  = UIColor.white.withAlphaComponent(0.15)
        borderMaterial.emission.contents = UIColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 0.6)  // Cyan glow
        borderMaterial.lightingModel = .constant
        borderMaterial.isDoubleSided = true
        borderPlane.materials = [borderMaterial]
        
        let borderNode = SCNNode(geometry: borderPlane)
        borderNode.position = SCNVector3(0, 0, -0.002)  // Slightly behind
        addChildNode(borderNode)
    }
}
