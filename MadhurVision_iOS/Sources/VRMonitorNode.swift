import SceneKit
import WebKit
import UIKit

/// A single unified floating monitor in VR space.
/// Features:
/// - Instant Frame 0 native render so the monitor is never transparent or blank.
/// - Robust serial snapshot pipeline (with mutex lock) to prevent WebKit IPC starvation.
/// - Built-in MadhurVision OS 2.0 with Google Browser, YouTube, and interactive Settings.
/// - Projector-style scaling that maintains fixed 16:9 web resolution.
class VRMonitorNode: SCNNode, WKScriptMessageHandler, WKNavigationDelegate {
    
    // Public Callbacks
    var onScaleChanged: ((CGFloat) -> Void)?
    var onIPDChanged: ((Float) -> Void)?
    var onRecalibrateRequested: (() -> Void)?
    var onPassthroughToggled: ((Bool) -> Void)?
    var onExitVRRequested: (() -> Void)?
    /// Delivers WebKit snapshots to VREngine's SceneKit render loop.
    var onSnapshotImage: ((UIImage) -> Void)?
    
    private var webView: WKWebView!
    let monitorWidth: CGFloat
    let monitorHeight: CGFloat
    private var snapshotTimer: Timer?
    private var isSnapshotting = false
    private var isShowingOS = true
    
    // Web rendering canvas dimensions (16:9)
    static let canvasWidth: CGFloat = 1440
    static let canvasHeight: CGFloat = 810
    
    // Store OS HTML for fast reload
    private static var cachedOSHTML: String?
    
    init(width: CGFloat = 2.4, height: CGFloat = 1.35) {
        self.monitorWidth = width
        self.monitorHeight = height
        super.init()
        
        // 1. Create the physical 3D plane
        let plane = SCNPlane(width: width, height: height)
        plane.cornerRadius = 0.04
        self.geometry = plane
        self.name = "vr_monitor"
        
        // 2. Add subtle glowing border frame
        addBorderFrame(width: width, height: height)
        
        // 3. INSTANT FRAME 0 RENDER: Draw native OS desktop immediately onto diffuse.contents
        // This guarantees the monitor is NEVER black or transparent from millisecond 0!
        let initialImage = VRMonitorNode.renderInstantPlaceholder()
        let material = SCNMaterial()
        material.diffuse.contents = initialImage
        material.isDoubleSided = true
        material.lightingModel = .constant
        plane.materials = [material]
        
        // 4. Initialize WKWebView
        setupWebView()
        
        // 5. Add to UIKit hierarchy and start snapshot pump
        attachWebViewAndStartCapture()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func cleanup() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    /// Converts a 3D world contact point into exact normalized (0.0 to 1.0) UV coordinates on the monitor surface.
    /// Uses physical geometry bounds rather than texture mapping channels for 100% mathematical precision.
    func uvCoordinates(fromWorldPoint worldPoint: SCNVector3) -> CGPoint {
        let local = convertPosition(worldPoint, from: nil)
        let u = CGFloat(min(max((local.x / Float(monitorWidth)) + 0.5, 0.0), 1.0))
        let v = CGFloat(min(max(0.5 - (local.y / Float(monitorHeight)), 0.0), 1.0))
        return CGPoint(x: u, y: v)
    }
    
    // MARK: - WebView Setup
    
    private func setupWebView() {
        let webConfig = WKWebViewConfiguration()
        webConfig.allowsInlineMediaPlayback = true
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        webConfig.allowsAirPlayForMediaPlayback = true
        webConfig.allowsPictureInPictureMediaPlayback = true
        webConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        
        // Swift <-> JS Bridge
        webConfig.userContentController.add(self, name: "vrOS")
        
        // Floating Dock script (injected on external websites)
        let dockScript = WKUserScript(
            source: VRMonitorNode.floatingDockJS(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webConfig.userContentController.addUserScript(dockScript)
        
        // Air Keyboard script
        let keyboardScript = WKUserScript(
            source: VRMonitorNode.airKeyboardJS(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webConfig.userContentController.addUserScript(keyboardScript)

        // Video Auto-Play & In-line Playback script
        let videoScript = WKUserScript(
            source: VRMonitorNode.videoPlaybackHelperJS(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        webConfig.userContentController.addUserScript(videoScript)
        
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: VRMonitorNode.canvasWidth, height: VRMonitorNode.canvasHeight),
            configuration: webConfig
        )
        webView.isOpaque = true
        webView.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0)
        webView.navigationDelegate = self
        
        // Desktop Mac Safari User Agent (serves full desktop HTML5 video with direct playback)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        
        // Load OS HTML
        let osHTML = VRMonitorNode.generateOSHTML()
        VRMonitorNode.cachedOSHTML = osHTML
        webView.loadHTMLString(osHTML, baseURL: nil)
    }
    
    private func attachWebViewAndStartCapture() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Find an active window to attach webView
            var targetWindow: UIWindow? = nil
            if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) as? UIWindowScene {
                targetWindow = windowScene.windows.first
            }
            if targetWindow == nil {
                targetWindow = UIApplication.shared.windows.first
            }
            
            if let window = targetWindow {
                // Place it at (0,0) inside the window behind the VR views
                // with alpha = 1.0 (so snapshots are fully opaque) and inserted at bottom (index 0)
                // so WebKit keeps the 60 FPS hardware video decoding engine active at full speed!
                self.webView.frame = CGRect(x: 0, y: 0, width: VRMonitorNode.canvasWidth, height: VRMonitorNode.canvasHeight)
                self.webView.isUserInteractionEnabled = false
                self.webView.alpha = 1.0 
                window.insertSubview(self.webView, at: 0)
            }
            
            self.startSnapshotPipeline()
        }
    }
    
    // MARK: - Serial Snapshot Pipeline (Mutex-Protected)
    
    private func startSnapshotPipeline() {
        // Initial capture after short delay for first layout pass
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.requestSnapshot()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.requestSnapshot()
        }
        
        // Periodic snapshot timer (12 FPS)
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.requestSnapshot()
        }
    }
    
    func requestSnapshot() {
        guard let webView = self.webView, !isSnapshotting else { return }
        isSnapshotting = true
        
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = true
        
        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self = self else { return }
            self.isSnapshotting = false
            
            if let image = image {
                onSnapshotImage?(image)
            }
        }
    }

    /// Must be called from VREngine.renderer(_:updateAtTime:) once the node
    /// belongs to a live scene.
    func applySnapshot(_ image: UIImage) {
        geometry?.firstMaterial?.diffuse.contents = image
    }
    
    // MARK: - Interaction Simulation
    
    func simulateClick(at uv: CGPoint) {
        let js = """
            (function() {
                var cssX = \(uv.x) * window.innerWidth;
                var cssY = \(uv.y) * window.innerHeight;
                var el = document.elementFromPoint(cssX, cssY);
                
                if(el) {
                    // Visual feedback ripple dot on the web canvas
                    var dot = document.createElement('div');
                    dot.style.cssText = 'position:fixed;left:'+(cssX-12)+'px;top:'+(cssY-12)+'px;width:24px;height:24px;background:rgba(0,212,255,0.9);border-radius:50%;z-index:999999;pointer-events:none;box-shadow:0 0 20px #00d4ff;transition:transform 0.35s, opacity 0.35s;';
                    document.body.appendChild(dot);
                    requestAnimationFrame(function(){ dot.style.transform = 'scale(2.2)'; dot.style.opacity = '0'; });
                    setTimeout(function(){ dot.remove(); }, 380);
                    
                    var opts = {bubbles:true, cancelable:true, view:window, clientX:cssX, clientY:cssY, screenX:cssX, screenY:cssY};
                    el.dispatchEvent(new PointerEvent('pointerdown', Object.assign({}, opts, {pointerType:'touch'})));
                    el.dispatchEvent(new PointerEvent('pointerup', Object.assign({}, opts, {pointerType:'touch'})));
                    el.dispatchEvent(new MouseEvent('mousedown', opts));
                    el.dispatchEvent(new MouseEvent('mouseup', opts));
                    el.dispatchEvent(new MouseEvent('click', opts));
                    
                    var clickable = el.closest('a, button, input, textarea, [role="button"], .card, .dock-item, .nav-btn, .vfd-btn');
                    if(clickable) {
                        if(typeof clickable.click === 'function') clickable.click();
                    } else if(typeof el.click === 'function') {
                        el.click();
                    }
                    
                    // Suppress native iOS mobile software keyboard and open VR Air Keyboard
                    var inputEl = el.closest('input, textarea, [contenteditable="true"], [role="textbox"], [role="combobox"]');
                    if(inputEl) {
                        inputEl.setAttribute('inputmode', 'none');
                        inputEl.focus();
                        var kb = document.getElementById('vr-air-keyboard');
                        if(kb) kb.classList.add('visible');
                    }
                }
            })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
        
        // Immediate snapshot triggers on click
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.requestSnapshot() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in self?.requestSnapshot() }
    }
    
    private var lastScrollTime = Date()
    
    func simulateScroll(by delta: CGFloat) {
        let now = Date()
        guard now.timeIntervalSince(lastScrollTime) >= 0.035 else { return } // Throttle to avoid WebKit queue flooding
        lastScrollTime = now
        
        let pixels = delta * 650
        let js = "window.scrollBy({top: \(pixels), behavior: 'auto'});"
        webView?.evaluateJavaScript(js, completionHandler: nil)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in self?.requestSnapshot() }
    }
    
    // MARK: - Navigation
    
    func navigateTo(url: URL) {
        isShowingOS = false
        webView?.load(URLRequest(url: url))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.requestSnapshot() }
    }
    
    func goHome() {
        isShowingOS = true
        if let html = VRMonitorNode.cachedOSHTML {
            webView?.loadHTMLString(html, baseURL: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.requestSnapshot() }
    }
    
    func goBack() {
        webView?.goBack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.requestSnapshot() }
    }
    
    func goForward() {
        webView?.goForward()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.requestSnapshot() }
    }
    
    func reload() {
        webView?.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.requestSnapshot() }
    }
    
    // MARK: - WKScriptMessageHandler (JS -> Swift Bridge)
    
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        
        switch action {
        case "navigate":
            if let urlStr = body["url"] as? String {
                var finalURL = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalURL.hasPrefix("http://") && !finalURL.hasPrefix("https://") {
                    if finalURL.contains(".") && !finalURL.contains(" ") {
                        finalURL = "https://" + finalURL
                    } else {
                        finalURL = "https://www.google.com/search?q=" + (finalURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? finalURL)
                    }
                }
                if let url = URL(string: finalURL) {
                    navigateTo(url: url)
                }
            }
        case "goHome":
            goHome()
        case "goBack":
            goBack()
        case "goForward":
            goForward()
        case "reload":
            reload()
        case "setScale":
            if let scale = body["scale"] as? Double {
                onScaleChanged?(CGFloat(scale))
            }
        case "setIPD":
            if let ipd = body["ipd"] as? Double {
                onIPDChanged?(Float(ipd) / 1000.0) // convert mm to meters
            }
        case "recalibrate":
            onRecalibrateRequested?()
        case "togglePassthrough":
            if let enabled = body["enabled"] as? Bool {
                onPassthroughToggled?(enabled)
            }
        case "exitVR":
            onExitVRRequested?()
        default:
            break
        }
    }
    
    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        requestSnapshot()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.requestSnapshot()
        }
    }
    
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        requestSnapshot()
    }
    
    // MARK: - Border Frame
    
    private func addBorderFrame(width: CGFloat, height: CGFloat) {
        let borderPlane = SCNPlane(width: width + 0.08, height: height + 0.08)
        borderPlane.cornerRadius = 0.06
        
        let borderMaterial = SCNMaterial()
        borderMaterial.diffuse.contents = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.15)
        borderMaterial.emission.contents = UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.8) // Glowing cyan frame
        borderMaterial.lightingModel = .constant
        borderMaterial.isDoubleSided = true
        borderPlane.materials = [borderMaterial]
        
        let borderNode = SCNNode(geometry: borderPlane)
        borderNode.name = "monitor_border"
        borderNode.position = SCNVector3(0, 0, -0.003)
        addChildNode(borderNode)
    }
    
    // MARK: - Instant Frame 0 Placeholder Renderer
    
    private static func renderInstantPlaceholder() -> UIImage {
        let size = CGSize(width: canvasWidth, height: canvasHeight)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            
            // Deep gradient background
            let colors = [
                UIColor(red: 0.05, green: 0.08, blue: 0.18, alpha: 1.0).cgColor,
                UIColor(red: 0.03, green: 0.04, blue: 0.10, alpha: 1.0).cgColor
            ]
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0.0, 1.0]) {
                ctx.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width, y: size.height), options: [])
            }
            
            // Dock background on left
            let dockRect = CGRect(x: 0, y: 0, width: 80, height: size.height)
            UIColor(red: 0.06, green: 0.08, blue: 0.14, alpha: 0.85).setFill()
            UIRectFill(dockRect)
            
            // Dock border line
            let dockLine = CGRect(x: 80, y: 0, width: 1, height: size.height)
            UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.3).setFill()
            UIRectFill(dockLine)
            
            // Top bar
            let topBar = CGRect(x: 80, y: 0, width: size.width - 80, height: 48)
            UIColor(white: 1.0, alpha: 0.04).setFill()
            UIRectFill(topBar)
            
            // Top title
            let topTitle = "MadhurVision OS 2.0"
            let topAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            topTitle.draw(at: CGPoint(x: 104, y: 14), withAttributes: topAttrs)
            
            // Hero Title
            let title = "MadhurVision"
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .black),
                .foregroundColor: UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 1.0)
            ]
            let titleSize = title.size(withAttributes: titleAttrs)
            title.draw(at: CGPoint(x: (size.width - titleSize.width) / 2.0 + 40, y: size.height * 0.25), withAttributes: titleAttrs)
            
            // Subtitle
            let sub = "Spatial VR Computing • Google Browser • Settings"
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: UIColor(white: 1.0, alpha: 0.6)
            ]
            let subSize = sub.size(withAttributes: subAttrs)
            sub.draw(at: CGPoint(x: (size.width - subSize.width) / 2.0 + 40, y: size.height * 0.25 + 70), withAttributes: subAttrs)
            
            // Search Box mockup
            let searchRect = CGRect(x: (size.width - 600) / 2.0 + 40, y: size.height * 0.45, width: 600, height: 50)
            let searchPath = UIBezierPath(roundedRect: searchRect, cornerRadius: 14)
            UIColor(white: 1.0, alpha: 0.08).setFill()
            searchPath.fill()
            UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.4).setStroke()
            searchPath.lineWidth = 1.5
            searchPath.stroke()
            
            let searchPlaceholder = "Search Google or type a URL..."
            let searchAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16, weight: .regular),
                .foregroundColor: UIColor(white: 1.0, alpha: 0.5)
            ]
            searchPlaceholder.draw(at: CGPoint(x: searchRect.origin.x + 20, y: searchRect.origin.y + 15), withAttributes: searchAttrs)
        }
    }
    
    // MARK: - Floating Dock JS (Overlay on external websites)
    
    private static func floatingDockJS() -> String {
        return """
        (function() {
            if (document.getElementById('loading-screen') || document.getElementById('desktop')) return;
            if (document.getElementById('vr-floating-dock')) return;
            
            var dock = document.createElement('div');
            dock.id = 'vr-floating-dock';
            dock.innerHTML = `
                <div class="vfd-btn" id="vfd-home" title="OS Home">🏠</div>
                <div class="vfd-btn" id="vfd-back" title="Back">◀</div>
                <div class="vfd-btn" id="vfd-fwd" title="Forward">▶</div>
                <div class="vfd-btn" id="vfd-reload" title="Refresh">↻</div>
            `;
            
            var style = document.createElement('style');
            style.textContent = `
                #vr-floating-dock {
                    position: fixed;
                    left: 12px;
                    top: 50%;
                    transform: translateY(-50%);
                    display: flex;
                    flex-direction: column;
                    gap: 10px;
                    z-index: 2147483647;
                    background: rgba(10, 15, 25, 0.85);
                    padding: 8px;
                    border-radius: 16px;
                    border: 1px solid rgba(0, 212, 255, 0.3);
                    box-shadow: 0 8px 32px rgba(0,0,0,0.7);
                    backdrop-filter: blur(10px);
                }
                .vfd-btn {
                    width: 44px;
                    height: 44px;
                    background: rgba(255,255,255,0.08);
                    border: 1px solid rgba(255,255,255,0.15);
                    border-radius: 12px;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-size: 20px;
                    cursor: pointer;
                    color: white;
                    user-select: none;
                    transition: all 0.2s;
                }
                .vfd-btn:hover { background: rgba(0, 212, 255, 0.25); border-color: #00d4ff; transform: scale(1.08); }
            `;
            document.head.appendChild(style);
            document.body.appendChild(dock);
            
            document.getElementById('vfd-home').addEventListener('click', function(e) {
                e.stopPropagation();
                window.webkit.messageHandlers.vrOS.postMessage({action:'goHome'});
            });
            document.getElementById('vfd-back').addEventListener('click', function(e) {
                e.stopPropagation();
                window.webkit.messageHandlers.vrOS.postMessage({action:'goBack'});
            });
            document.getElementById('vfd-fwd').addEventListener('click', function(e) {
                e.stopPropagation();
                window.webkit.messageHandlers.vrOS.postMessage({action:'goForward'});
            });
            document.getElementById('vfd-reload').addEventListener('click', function(e) {
                e.stopPropagation();
                window.webkit.messageHandlers.vrOS.postMessage({action:'reload'});
            });
        })();
        """
    }

    // MARK: - Video Playback Helper JS
    
    private static func videoPlaybackHelperJS() -> String {
        return """
        (function() {
            // Ensure inline video playback flags on all video elements
            function enforceInlineVideos() {
                var videos = document.querySelectorAll('video');
                videos.forEach(function(v) {
                    if (!v.hasAttribute('playsinline')) v.setAttribute('playsinline', 'true');
                    if (!v.hasAttribute('webkit-playsinline')) v.setAttribute('webkit-playsinline', 'true');
                });
            }
            setInterval(enforceInlineVideos, 1000);
        })();
        """
    }
    
    // MARK: - Air Keyboard JS (Universal on all websites & apps)
    
    private static func airKeyboardJS() -> String {
        return """
        (function() {
            if (document.getElementById('vr-air-keyboard')) return;
            
            var style = document.createElement('style');
            style.textContent = `
                #vr-air-keyboard {
                    position: fixed;
                    bottom: -70%;
                    left: 50%;
                    transform: translateX(-50%);
                    width: 92%;
                    max-width: 980px;
                    background: rgba(10, 16, 28, 0.97);
                    border: 2px solid rgba(0, 212, 255, 0.4);
                    border-radius: 20px 20px 0 0;
                    padding: 14px 18px 20px;
                    display: flex;
                    flex-direction: column;
                    gap: 8px;
                    z-index: 2147483647;
                    transition: bottom 0.28s cubic-bezier(0.2, 0.8, 0.2, 1);
                    box-shadow: 0 -15px 60px rgba(0,0,0,0.9), 0 0 30px rgba(0,212,255,0.2);
                    backdrop-filter: blur(20px);
                    -webkit-backdrop-filter: blur(20px);
                }
                #vr-air-keyboard.visible { bottom: 0 !important; }
                .kb-topbar {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    padding: 0 4px 6px;
                    border-bottom: 1px solid rgba(0, 212, 255, 0.2);
                    margin-bottom: 4px;
                }
                .kb-title { font-size: 13px; font-weight: 700; color: #00d4ff; letter-spacing: 1px; text-transform: uppercase; font-family: -apple-system, sans-serif; }
                .kb-close-btn {
                    background: rgba(255,255,255,0.12);
                    border: 1px solid rgba(255,255,255,0.2);
                    color: #fff;
                    font-size: 13px;
                    font-weight: 600;
                    padding: 4px 14px;
                    border-radius: 20px;
                    cursor: pointer;
                    font-family: -apple-system, sans-serif;
                }
                .kb-close-btn:active { background: #ff0055; }
                .kb-row { display: flex; justify-content: center; gap: 6px; }
                .kb-key {
                    background: rgba(255,255,255,0.12);
                    border: 1px solid rgba(255,255,255,0.18);
                    color: white;
                    font-size: 18px;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-weight: 600;
                    padding: 11px 0;
                    flex: 1;
                    border-radius: 8px;
                    text-align: center;
                    cursor: pointer;
                    user-select: none;
                    -webkit-user-select: none;
                    transition: transform 0.1s, background 0.1s;
                }
                .kb-key:active { background: rgba(0,212,255,0.5); transform: scale(0.92); }
                .kb-key.action { background: rgba(0,212,255,0.22); border-color: rgba(0,212,255,0.4); color: #00d4ff; }
                .kb-key.wide { flex: 1.6; }
                .kb-key.space { flex: 5.2; }
            `;
            document.head.appendChild(style);
            
            var kb = document.createElement('div');
            kb.id = 'vr-air-keyboard';
            
            var topBar = document.createElement('div');
            topBar.className = 'kb-topbar';
            topBar.innerHTML = '<span class="kb-title">⌨️ VR Air Keyboard</span><button class="kb-close-btn" id="kb-close-action">✕ Done</button>';
            kb.appendChild(topBar);
            
            var layout = [
                ['1','2','3','4','5','6','7','8','9','0'],
                ['Q','W','E','R','T','Y','U','I','O','P'],
                ['A','S','D','F','G','H','J','K','L'],
                ['Z','X','C','V','B','N','M','DEL'],
                ['https://','@','.com','SPACE','.','↵ GO']
            ];
            
            var currentTargetInput = null;
            
            layout.forEach(function(row) {
                var rowDiv = document.createElement('div');
                rowDiv.className = 'kb-row';
                row.forEach(function(key) {
                    var btn = document.createElement('div');
                    btn.className = 'kb-key';
                    if (key === 'SPACE') { btn.classList.add('space'); btn.textContent = 'Space'; }
                    else if (key === 'DEL') { btn.classList.add('wide', 'action'); btn.textContent = '⌫'; }
                    else if (key === '↵ GO') { btn.classList.add('wide', 'action'); btn.textContent = '↵ Search'; }
                    else if (key === '.com') { btn.classList.add('wide'); btn.textContent = '.com'; }
                    else if (key === 'https://') { btn.classList.add('wide'); btn.textContent = 'https://'; }
                    else { btn.textContent = key; }
                    
                    btn.addEventListener('mousedown', function(e) { e.preventDefault(); });
                    btn.addEventListener('click', function(e) {
                        e.preventDefault();
                        e.stopPropagation();
                        
                        var target = currentTargetInput || document.activeElement;
                        if (!target) return;
                        
                        if (target.isContentEditable) {
                            if (key === 'DEL') {
                                document.execCommand('delete', false, null);
                            } else if (key === 'SPACE') {
                                document.execCommand('insertText', false, ' ');
                            } else if (key === '↵ GO') {
                                kb.classList.remove('visible');
                                return;
                            } else {
                                var txt = (key === 'https://' || key === '.com' || key === '@' || key === '.') ? key : key.toLowerCase();
                                document.execCommand('insertText', false, txt);
                            }
                            return;
                        }
                        
                        if (target.tagName !== 'INPUT' && target.tagName !== 'TEXTAREA') return;
                        
                        if (key === 'DEL') {
                            target.value = target.value.slice(0, -1);
                        } else if (key === 'SPACE') {
                            target.value += ' ';
                        } else if (key === '↵ GO') {
                            kb.classList.remove('visible');
                            if (target.form) { target.form.submit(); }
                            else {
                                var ev = new KeyboardEvent('keydown', {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true});
                                target.dispatchEvent(ev);
                            }
                            target.blur();
                            return;
                        } else if (key === '.com') { target.value += '.com'; }
                        else if (key === 'https://') { target.value += 'https://'; }
                        else if (key === '@') { target.value += '@'; }
                        else if (key === '.') { target.value += '.'; }
                        else { target.value += key.toLowerCase(); }
                        
                        target.dispatchEvent(new Event('input', { bubbles: true }));
                        target.dispatchEvent(new Event('change', { bubbles: true }));
                    });
                    rowDiv.appendChild(btn);
                });
                kb.appendChild(rowDiv);
            });
            
            document.body.appendChild(kb);
            
            document.getElementById('kb-close-action').addEventListener('click', function(e) {
                e.preventDefault();
                e.stopPropagation();
                kb.classList.remove('visible');
                if (currentTargetInput) currentTargetInput.blur();
            });
            
            function showKeyboardFor(el) {
                if (!el) return;
                var isInput = el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable || el.getAttribute('role') === 'textbox' || el.getAttribute('role') === 'combobox';
                if (isInput) {
                    currentTargetInput = el;
                    kb.classList.add('visible');
                }
            }
            
            document.addEventListener('focusin', function(e) { showKeyboardFor(e.target); }, true);
            document.addEventListener('click', function(e) {
                var el = e.target.closest('input, textarea, [contenteditable="true"], [role="textbox"], [role="combobox"], #search-bar');
                if (el) {
                    showKeyboardFor(el);
                } else if (!e.target.closest('#vr-air-keyboard')) {
                    // Clicked outside on page content — close keyboard
                    kb.classList.remove('visible');
                }
            }, true);
        })();
        """
    }
    
    // MARK: - MadhurVision OS 2.0 Full HTML/CSS/JS
    
    private static func generateOSHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <title>MadhurVision OS 2.0</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                background: #080b14;
                color: #fff;
                width: 100vw;
                height: 100vh;
                overflow: hidden;
                user-select: none;
                -webkit-user-select: none;
            }
            
            /* Loading Screen */
            #loading-screen {
                position: fixed;
                inset: 0;
                background: radial-gradient(circle at center, #10192e 0%, #080b14 100%);
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                z-index: 10000;
                transition: opacity 0.5s ease;
            }
            #loading-screen.hidden { opacity: 0; pointer-events: none; }
            .loading-title {
                font-size: 60px;
                font-weight: 800;
                letter-spacing: 2px;
                background: linear-gradient(135deg, #00d4ff, #7b2ff7, #ff007f);
                -webkit-background-clip: text;
                -webkit-text-fill-color: transparent;
                margin-bottom: 12px;
            }
            .loading-sub {
                font-size: 20px;
                color: rgba(255,255,255,0.6);
                margin-bottom: 36px;
            }
            .loading-bar-track {
                width: 320px; height: 6px;
                background: rgba(255,255,255,0.1);
                border-radius: 3px; overflow: hidden;
            }
            .loading-bar-fill {
                height: 100%; width: 0%;
                background: linear-gradient(90deg, #00d4ff, #7b2ff7);
                border-radius: 3px;
                animation: loadFill 1.8s cubic-bezier(0.1, 0.7, 0.1, 1) forwards;
            }
            @keyframes loadFill { 0%{width:0%} 100%{width:100%} }
            
            /* Desktop Layout */
            #desktop {
                display: none;
                width: 100%;
                height: 100%;
            }
            #desktop.visible { display: flex; }
            
            /* Sidebar Dock */
            #dock {
                width: 80px;
                height: 100%;
                background: rgba(14, 20, 32, 0.75);
                border-right: 1px solid rgba(0, 212, 255, 0.15);
                display: flex;
                flex-direction: column;
                align-items: center;
                padding: 20px 0;
                gap: 16px;
                flex-shrink: 0;
                backdrop-filter: blur(12px);
            }
            .dock-item {
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 4px;
                cursor: pointer;
            }
            .dock-icon {
                width: 56px;
                height: 56px;
                border-radius: 16px;
                display: flex;
                align-items: center;
                justify-content: center;
                font-size: 28px;
                background: rgba(255,255,255,0.06);
                border: 1px solid rgba(255,255,255,0.1);
                transition: all 0.2s ease;
            }
            .dock-item:hover .dock-icon {
                background: rgba(0, 212, 255, 0.2);
                border-color: #00d4ff;
                transform: scale(1.08);
            }
            .dock-icon.active {
                background: rgba(0, 212, 255, 0.25);
                border-color: #00d4ff;
                box-shadow: 0 0 16px rgba(0, 212, 255, 0.4);
            }
            .dock-label { font-size: 11px; color: rgba(255,255,255,0.6); font-weight: 500; }
            .dock-spacer { flex: 1; }
            
            /* Main Content Area */
            #main-area {
                flex: 1;
                display: flex;
                flex-direction: column;
                overflow: hidden;
                background: radial-gradient(ellipse at 50% 0%, #111e38 0%, #080b14 70%);
            }
            
            /* Top Navigation Bar */
            #top-bar {
                height: 48px;
                background: rgba(255,255,255,0.03);
                border-bottom: 1px solid rgba(255,255,255,0.08);
                display: flex;
                align-items: center;
                padding: 0 20px;
                gap: 16px;
                flex-shrink: 0;
            }
            .top-title { font-size: 16px; font-weight: 700; color: rgba(255,255,255,0.9); }
            .top-spacer { flex: 1; }
            .top-badge {
                font-size: 12px;
                padding: 4px 10px;
                border-radius: 20px;
                background: rgba(0,212,255,0.12);
                border: 1px solid rgba(0,212,255,0.3);
                color: #00d4ff;
                font-weight: 600;
            }
            .top-clock { font-size: 15px; font-weight: 600; color: rgba(255,255,255,0.7); }
            
            /* Omnibar */
            #url-bar-container {
                height: 52px;
                background: rgba(14, 20, 32, 0.6);
                border-bottom: 1px solid rgba(0, 212, 255, 0.15);
                padding: 6px 20px;
                display: flex;
                gap: 10px;
                align-items: center;
                flex-shrink: 0;
            }
            .nav-btn {
                width: 38px; height: 38px; border-radius: 10px;
                background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.15);
                color: white; font-size: 16px; cursor: pointer;
                display: flex; align-items: center; justify-content: center;
                transition: all 0.2s;
            }
            .nav-btn:hover { background: rgba(0,212,255,0.25); border-color: #00d4ff; }
            #url-input {
                flex: 1; height: 38px;
                background: rgba(255,255,255,0.08);
                border: 1px solid rgba(255,255,255,0.2);
                border-radius: 10px;
                color: #fff;
                font-size: 15px;
                padding: 0 16px;
                outline: none;
                transition: all 0.2s;
            }
            #url-input:focus { border-color: #00d4ff; background: rgba(0,212,255,0.1); box-shadow: 0 0 12px rgba(0,212,255,0.3); }
            .go-btn {
                padding: 0 20px; height: 38px;
                background: linear-gradient(135deg, #00d4ff, #0077ff);
                border: none; border-radius: 10px;
                color: white; font-weight: 700; font-size: 14px;
                cursor: pointer;
            }
            .go-btn:hover { transform: scale(1.04); }
            
            /* Content Area */
            #active-content { flex: 1; overflow-y: auto; position: relative; padding: 24px 30px; }
            .content-view { display: none; width: 100%; height: 100%; }
            .content-view.active { display: block; }
            
            /* Home Grid */
            .home-hero { text-align: center; margin: 20px 0 35px; }
            .home-logo-text {
                font-size: 56px; font-weight: 800;
                background: linear-gradient(135deg, #00d4ff, #a259ff);
                -webkit-background-clip: text; -webkit-text-fill-color: transparent;
            }
            .home-desc { font-size: 18px; color: rgba(255,255,255,0.5); margin-top: 6px; }
            
            .app-grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                gap: 20px;
                max-width: 1000px;
                margin: 0 auto;
            }
            .app-card {
                background: rgba(255,255,255,0.05);
                border: 1px solid rgba(255,255,255,0.1);
                border-radius: 18px;
                padding: 24px 20px;
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 12px;
                cursor: pointer;
                transition: all 0.25s ease;
            }
            .app-card:hover {
                background: rgba(0, 212, 255, 0.15);
                border-color: #00d4ff;
                transform: translateY(-4px);
                box-shadow: 0 10px 30px rgba(0, 212, 255, 0.2);
            }
            .app-card-icon { font-size: 44px; }
            .app-card-title { font-size: 18px; font-weight: 700; }
            .app-card-desc { font-size: 12px; color: rgba(255,255,255,0.5); text-align: center; }
            
            /* Settings View */
            .settings-container { max-width: 900px; margin: 0 auto; display: flex; flex-direction: column; gap: 20px; }
            .settings-group {
                background: rgba(255,255,255,0.04);
                border: 1px solid rgba(255,255,255,0.08);
                border-radius: 18px;
                padding: 20px 24px;
            }
            .settings-group-title {
                font-size: 13px; font-weight: 700; text-transform: uppercase;
                letter-spacing: 1.5px; color: #00d4ff; margin-bottom: 16px;
            }
            .settings-row {
                display: flex; align-items: center; justify-content: space-between;
                padding: 14px 0; border-bottom: 1px solid rgba(255,255,255,0.05);
            }
            .settings-row:last-child { border-bottom: none; }
            .row-info h4 { font-size: 16px; font-weight: 600; }
            .row-info p { font-size: 13px; color: rgba(255,255,255,0.45); margin-top: 2px; }
            
            .preset-btn-group { display: flex; gap: 8px; }
            .preset-btn {
                padding: 8px 14px; border-radius: 10px;
                background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.15);
                color: white; font-size: 13px; font-weight: 600; cursor: pointer;
            }
            .preset-btn.active { background: #00d4ff; color: #000; border-color: #00d4ff; font-weight: 700; }
            
            .slider-ctrl { display: flex; align-items: center; gap: 12px; }
            .slider-ctrl input[type="range"] {
                width: 160px; accent-color: #00d4ff; cursor: pointer;
            }
            .slider-val { font-size: 14px; font-weight: 600; color: #00d4ff; min-width: 48px; }
            
            .action-btn {
                padding: 10px 20px; border-radius: 10px;
                background: rgba(0, 212, 255, 0.15); border: 1px solid #00d4ff;
                color: #00d4ff; font-weight: 700; font-size: 14px; cursor: pointer;
                transition: all 0.2s;
            }
            .action-btn:hover { background: #00d4ff; color: #000; }
        </style>
        </head>
        <body>
        
        <!-- LOADING SCREEN -->
        <div id="loading-screen">
            <div class="loading-title">MadhurVision</div>
            <div class="loading-sub">MadhurVision OS 2.0 • Ultra HD VR</div>
            <div class="loading-bar-track"><div class="loading-bar-fill"></div></div>
        </div>
        
        <!-- DESKTOP -->
        <div id="desktop">
            <!-- DOCK -->
            <div id="dock">
                <div class="dock-item" onclick="switchApp('home')">
                    <div class="dock-icon active" id="dock-home">🏠</div>
                    <div class="dock-label">Home</div>
                </div>
                <div class="dock-item" onclick="launchGoogle()">
                    <div class="dock-icon" id="dock-browser">🌐</div>
                    <div class="dock-label">Google</div>
                </div>
                <div class="dock-item" onclick="launchYouTube()">
                    <div class="dock-icon" id="dock-youtube">📺</div>
                    <div class="dock-label">YouTube</div>
                </div>
                <div class="dock-item" onclick="switchApp('settings')">
                    <div class="dock-icon" id="dock-settings">⚙️</div>
                    <div class="dock-label">Settings</div>
                </div>
                <div class="dock-spacer"></div>
                <div class="dock-item" onclick="wkMsg('recalibrate')">
                    <div class="dock-icon" title="Recalibrate Center">🎯</div>
                    <div class="dock-label">Center</div>
                </div>
            </div>
            
            <!-- MAIN AREA -->
            <div id="main-area">
                <!-- TOP BAR -->
                <div id="top-bar">
                    <div class="top-title" id="app-title">Home</div>
                    <div class="top-spacer"></div>
                    <div class="top-badge" style="background:rgba(123,47,247,0.2); border-color:#a259ff; color:#d09cf7;">🎮 Wand: http://\(AirMouseServer.shared.getLocalIPAddress()):8080</div>
                    <div class="top-badge">120 Hz VR</div>
                    <div class="top-clock" id="clock">12:00</div>
                </div>
                
                <!-- OMNIBAR (URL & SEARCH) -->
                <div id="url-bar-container">
                    <button class="nav-btn" onclick="wkMsg('goBack')">◀</button>
                    <button class="nav-btn" onclick="wkMsg('goForward')">▶</button>
                    <button class="nav-btn" onclick="wkMsg('reload')">↻</button>
                    <input type="text" id="url-input" placeholder="Search Google or enter URL (e.g. google.com, youtube.com)..." value="https://www.google.com">
                    <button class="go-btn" onclick="submitURL()">Open ↵</button>
                </div>
                
                <!-- CONTENT CONTAINER -->
                <div id="active-content">
                    <!-- HOME VIEW -->
                    <div class="content-view active" id="home-view">
                        <div class="home-hero">
                            <div class="home-logo-text">MadhurVision</div>
                            <div class="home-desc">Your Spatial VR Computing System</div>
                        </div>
                        
                        <div class="app-grid">
                            <div class="app-card" onclick="launchGoogle()">
                                <div class="app-card-icon">🔍</div>
                                <div class="app-card-title">Google Search</div>
                                <div class="app-card-desc">Browse the web with desktop-class performance</div>
                            </div>
                            <div class="app-card" onclick="launchYouTube()">
                                <div class="app-card-icon">▶️</div>
                                <div class="app-card-title">YouTube</div>
                                <div class="app-card-desc">Watch videos in giant cinema theater screen</div>
                            </div>
                            <div class="app-card" onclick="openPresetURL('https://www.wikipedia.org')">
                                <div class="app-card-icon">📚</div>
                                <div class="app-card-title">Wikipedia</div>
                                <div class="app-card-desc">Explore spatial knowledge & articles</div>
                            </div>
                            <div class="app-card" onclick="openPresetURL('https://www.reddit.com')">
                                <div class="app-card-icon">💬</div>
                                <div class="app-card-title">Reddit</div>
                                <div class="app-card-desc">Community discussions & news</div>
                            </div>
                            <div class="app-card" onclick="openPresetURL('https://fast.com')">
                                <div class="app-card-icon">⚡</div>
                                <div class="app-card-title">Speed Test</div>
                                <div class="app-card-desc">Check your network streaming bandwidth</div>
                            </div>
                            <div class="app-card" onclick="switchApp('settings')">
                                <div class="app-card-icon">⚙️</div>
                                <div class="app-card-title">System Settings</div>
                                <div class="app-card-desc">Adjust screen size, IPD, and tracking</div>
                            </div>
                        </div>
                    </div>
                    
                    <!-- SETTINGS VIEW -->
                    <div class="content-view" id="settings-view">
                        <div class="settings-container">
                            <div class="settings-group">
                                <div class="settings-group-title">Display & Screen Sizing</div>
                                <div class="settings-row">
                                    <div class="row-info">
                                        <h4>Virtual Screen Preset</h4>
                                        <p>Locked virtual screen scale (projector mode)</p>
                                    </div>
                                    <div class="preset-btn-group">
                                        <button class="preset-btn" onclick="setPresetScale(0.7, this)">10" Mini</button>
                                        <button class="preset-btn active" onclick="setPresetScale(1.0, this)">12" Std</button>
                                        <button class="preset-btn" onclick="setPresetScale(1.3, this)">15" Pro</button>
                                        <button class="preset-btn" onclick="setPresetScale(2.0, this)">Cinema 50"</button>
                                    </div>
                                </div>
                                <div class="settings-row">
                                    <div class="row-info">
                                        <h4>IPD Offset (Lens Distance)</h4>
                                        <p>Align stereo cameras to your eye separation</p>
                                    </div>
                                    <div class="slider-ctrl">
                                        <input type="range" id="ipd-slider" min="55" max="75" value="65" oninput="updateIPD(this.value)">
                                        <span class="slider-val" id="ipd-val">65 mm</span>
                                    </div>
                                </div>
                            </div>
                            
                            <div class="settings-group">
                                <div class="settings-group-title">Orientation & Tracking</div>
                                <div class="settings-row">
                                    <div class="row-info">
                                        <h4>Recalibrate Center View</h4>
                                        <p>Reset yaw and center the monitor straight ahead</p>
                                    </div>
                                    <button class="action-btn" onclick="wkMsg('recalibrate')">🎯 Recalibrate Center</button>
                                </div>
                                <div class="settings-row">
                                    <div class="row-info">
                                        <h4>Mixed Reality Passthrough</h4>
                                        <p>Blend rear camera video into VR background</p>
                                    </div>
                                    <button class="action-btn" id="passthrough-btn" onclick="togglePassthrough()">Disable MR</button>
                                </div>
                            </div>
                            
                            <div class="settings-group">
                                <div class="settings-group-title">System Information</div>
                                <div class="settings-row">
                                    <div class="row-info">
                                        <h4>MadhurVision OS Version</h4>
                                        <p>Unified Spatial VR Environment</p>
                                    </div>
                                    <span style="color:rgba(255,255,255,0.7); font-weight:600;">v2.0 (Build 26.0)</span>
                                </div>
                                <div class="settings-row">
                                    <div class="row-info">
                                        <h4>Display Mode</h4>
                                        <p>High-Fidelity Dual-Eye Stereo</p>
                                    </div>
                                    <span style="color:#00d4ff; font-weight:600;">1440x810 Internal Canvas</span>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <script>
        // Boot Sequence
        setTimeout(function() {
            var loader = document.getElementById('loading-screen');
            if (loader) loader.classList.add('hidden');
            setTimeout(function() {
                if (loader) loader.style.display = 'none';
                document.getElementById('desktop').classList.add('visible');
            }, 500);
        }, 1200);
        
        // Clock
        function updateClock() {
            var now = new Date();
            document.getElementById('clock').textContent =
                now.getHours().toString().padStart(2,'0') + ':' + now.getMinutes().toString().padStart(2,'0');
        }
        updateClock(); setInterval(updateClock, 10000);
        
        // Swift Bridge Helper
        function wkMsg(action, data) {
            var msg = {action: action};
            if (data) Object.assign(msg, data);
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vrOS) {
                window.webkit.messageHandlers.vrOS.postMessage(msg);
            }
        }
        
        // App Switching
        var currentApp = 'home';
        function switchApp(app) {
            currentApp = app;
            document.querySelectorAll('.dock-icon').forEach(function(i) { i.classList.remove('active'); });
            var di = document.getElementById('dock-' + app);
            if (di) di.classList.add('active');
            
            var titles = {home: 'Home', settings: 'System Settings'};
            document.getElementById('app-title').textContent = titles[app] || app;
            
            document.querySelectorAll('.content-view').forEach(function(v) { v.classList.remove('active'); });
            var target = document.getElementById(app + '-view');
            if (target) target.classList.add('active');
        }
        
        // Navigation Shortcuts
        function launchGoogle() {
            wkMsg('navigate', {url: 'https://www.google.com'});
        }
        
        function launchYouTube() {
            wkMsg('navigate', {url: 'https://www.youtube.com'});
        }
        
        function openPresetURL(url) {
            wkMsg('navigate', {url: url});
        }
        
        function submitURL() {
            var url = document.getElementById('url-input').value;
            if (url) wkMsg('navigate', {url: url});
        }
        
        document.getElementById('url-input').addEventListener('keydown', function(e) {
            if (e.key === 'Enter') {
                e.preventDefault();
                submitURL();
            }
        });
        
        // Settings Controls
        function setPresetScale(scale, btn) {
            document.querySelectorAll('.preset-btn').forEach(function(b) { b.classList.remove('active'); });
            btn.classList.add('active');
            wkMsg('setScale', {scale: scale});
        }
        
        function updateIPD(val) {
            document.getElementById('ipd-val').textContent = val + ' mm';
            wkMsg('setIPD', {ipd: parseFloat(val)});
        }
        
        var passthroughEnabled = true;
        function togglePassthrough() {
            passthroughEnabled = !passthroughEnabled;
            var btn = document.getElementById('passthrough-btn');
            btn.textContent = passthroughEnabled ? 'Disable MR' : 'Enable MR';
            btn.style.borderColor = passthroughEnabled ? '#00d4ff' : 'rgba(255,255,255,0.3)';
            wkMsg('togglePassthrough', {enabled: passthroughEnabled});
        }
        </script>
        </body>
        </html>
        """
    }
}
