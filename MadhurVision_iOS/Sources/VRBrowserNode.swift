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
        let resolutionMultiplier: CGFloat = 800
        let webWidth = width * resolutionMultiplier
        let webHeight = height * resolutionMultiplier
        
        let webConfig = WKWebViewConfiguration()
        webConfig.allowsInlineMediaPlayback = true
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        
        // Force Desktop mode so YouTube doesn't load the broken mobile site at 2000px wide
        let prefs = WKWebpagePreferences()
        prefs.preferredContentMode = .desktop
        webConfig.defaultWebpagePreferences = prefs
        
        // Inject Air Keyboard
        let keyboardJS = VRBrowserNode.airKeyboardScript()
        let userScript = WKUserScript(source: keyboardJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        webConfig.userContentController.addUserScript(userScript)
        
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: webWidth, height: webHeight), configuration: webConfig)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        
        // Spoof Mac Safari User-Agent to guarantee desktop site delivery
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0.3 Safari/605.1.15"
        
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
        
        // 5. Add to view hierarchy (required for WKWebView to render in iOS 14+)
        DispatchQueue.main.async {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                // Place it exactly on screen at 0,0 with full size.
                // We set alpha to 1.0 so SceneKit captures it at 100% opacity.
                // To hide it from the user's direct 2D view, we insert it at index 0
                // so it sits BEHIND the SwiftUI VR scene (which has a black background).
                self.webView.frame = CGRect(x: 0, y: 0, width: webWidth, height: webHeight)
                self.webView.alpha = 1.0
                self.webView.isUserInteractionEnabled = false
                window.insertSubview(self.webView, at: 0)
            }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func cleanup() {
        webView.stopLoading()
        webView.removeFromSuperview()
        webView = nil
    }
    
    // In Phase 2, this function will be called by a raycast hit to simulate a click
    func simulateClick(at uv: CGPoint) {
        let x = uv.x * webView.bounds.width
        let y = uv.y * webView.bounds.height
        
        let js = """
            var el = document.elementFromPoint(\(x), \(y));
            if(el) {
                var down = new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window, clientX: \(x), clientY: \(y) });
                var up = new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window, clientX: \(x), clientY: \(y) });
                var click = new MouseEvent('click', { bubbles: true, cancelable: true, view: window, clientX: \(x), clientY: \(y) });
                
                el.dispatchEvent(down);
                el.dispatchEvent(up);
                el.dispatchEvent(click);
                
                // Fallback for some stubborn elements
                if (typeof el.click === 'function') {
                    el.click();
                }
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
    
    // MARK: - Air Keyboard JS
    
    private static func airKeyboardScript() -> String {
        return """
        function injectVRKeyboard() {
            if (document.getElementById('vr-air-keyboard')) return;
            
            var style = document.createElement('style');
            style.innerHTML = `
                #vr-air-keyboard {
                    position: fixed;
                    bottom: -400px;
                    left: 50%;
                    transform: translateX(-50%);
                    width: 80%;
                    max-width: 800px;
                    background: rgba(20, 20, 20, 0.95);
                    backdrop-filter: blur(20px);
                    border-radius: 20px 20px 0 0;
                    padding: 20px;
                    display: flex;
                    flex-direction: column;
                    gap: 12px;
                    z-index: 2147483647;
                    transition: bottom 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
                    box-shadow: 0 -10px 40px rgba(0,0,0,0.5);
                    border: 1px solid rgba(255,255,255,0.1);
                    pointer-events: auto;
                }
                #vr-air-keyboard.visible {
                    bottom: 0px;
                }
                .vr-key-row {
                    display: flex;
                    justify-content: center;
                    gap: 12px;
                }
                .vr-key {
                    background: rgba(255,255,255,0.15);
                    border: 1px solid rgba(255,255,255,0.2);
                    color: white;
                    font-size: 26px;
                    font-family: -apple-system, sans-serif;
                    font-weight: 500;
                    padding: 18px 0;
                    flex: 1;
                    border-radius: 12px;
                    text-align: center;
                    cursor: pointer;
                    user-select: none;
                    transition: all 0.1s;
                }
                .vr-key:hover {
                    background: rgba(255,255,255,0.3);
                }
                .vr-key:active {
                    background: rgba(255,255,255,0.5);
                    transform: scale(0.95);
                }
                .vr-key.wide { flex: 1.5; }
                .vr-key.space { flex: 5; }
            `;
            document.head.appendChild(style);
            
            var kb = document.createElement('div');
            kb.id = 'vr-air-keyboard';
            
            // We use mousedown to prevent input from losing focus!
            kb.addEventListener('mousedown', function(e) {
                e.preventDefault();
            });
            
            var layout = [
                ['Q','W','E','R','T','Y','U','I','O','P'],
                ['A','S','D','F','G','H','J','K','L'],
                ['Z','X','C','V','B','N','M','DEL'],
                ['SPACE', 'ENTER']
            ];
            
            layout.forEach(row => {
                var rowDiv = document.createElement('div');
                rowDiv.className = 'vr-key-row';
                row.forEach(key => {
                    var btn = document.createElement('div');
                    btn.className = 'vr-key';
                    if (key === 'SPACE') btn.classList.add('space');
                    if (key === 'DEL' || key === 'ENTER') btn.classList.add('wide');
                    btn.innerText = key;
                    
                    btn.addEventListener('click', function(e) {
                        e.preventDefault();
                        e.stopPropagation();
                        
                        var el = document.activeElement;
                        if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) return;
                        
                        if (key === 'DEL') {
                            el.value = el.value.slice(0, -1);
                        } else if (key === 'SPACE') {
                            el.value += ' ';
                        } else if (key === 'ENTER') {
                            if (el.form) {
                                el.form.submit();
                            } else {
                                // Close keyboard
                                kb.classList.remove('visible');
                                el.blur();
                            }
                        } else {
                            el.value += key.toLowerCase();
                        }
                        
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                    });
                    
                    // Also prevent default on mousedown for each button
                    btn.addEventListener('mousedown', function(e) {
                        e.preventDefault();
                    });
                    
                    rowDiv.appendChild(btn);
                });
                kb.appendChild(rowDiv);
            });
            
            document.body.appendChild(kb);
            
            document.addEventListener('focusin', function(e) {
                if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') {
                    document.getElementById('vr-air-keyboard').classList.add('visible');
                }
            });
            
            document.addEventListener('focusout', function(e) {
                // Delay hiding slightly to allow for key clicks without glitching
                setTimeout(function() {
                    document.getElementById('vr-air-keyboard').classList.remove('visible');
                }, 200);
            });
        }
        
        // Use setInterval to ensure it gets injected even if SPA frameworks overwrite the body
        setInterval(function() {
            if (!document.getElementById('vr-air-keyboard') && document.body) {
                injectVRKeyboard();
            }
        }, 2000);
        """
    }
}
