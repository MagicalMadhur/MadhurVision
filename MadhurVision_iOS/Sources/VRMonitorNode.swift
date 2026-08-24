import SceneKit
import WebKit
import UIKit

/// A single unified floating monitor in VR space.
/// Contains the entire OS: loading screen, dock sidebar, browser, settings, and air keyboard.
/// Everything lives inside ONE WKWebView mapped to ONE 3D plane.
class VRMonitorNode: SCNNode, WKScriptMessageHandler {
    
    private var webView: WKWebView!
    private let monitorWidth: CGFloat
    private let monitorHeight: CGFloat
    
    /// Callback when the OS HTML requests navigation to a URL (browser app)
    var onNavigate: ((URL) -> Void)?
    
    init(width: CGFloat = 2.4, height: CGFloat = 1.35) {
        self.monitorWidth = width
        self.monitorHeight = height
        super.init()
        
        // 1. Create the physical 3D plane (16:9 locked aspect ratio)
        let plane = SCNPlane(width: width, height: height)
        plane.cornerRadius = 0.04
        self.geometry = plane
        self.name = "vr_monitor"
        
        // Add a glowing border frame
        addBorderFrame(width: width, height: height)
        
        // 2. Initialize WKWebView
        let resolutionMultiplier: CGFloat = 500
        let webWidth = width * resolutionMultiplier
        let webHeight = height * resolutionMultiplier
        
        let webConfig = WKWebViewConfiguration()
        webConfig.allowsInlineMediaPlayback = true
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        
        // Allow JS to communicate back to Swift
        webConfig.userContentController.add(self, name: "vrOS")
        
        // Inject viewport meta to prevent scaling issues
        let viewportScript = WKUserScript(
            source: """
            var meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            document.head.appendChild(meta);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webConfig.userContentController.addUserScript(viewportScript)
        
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: webWidth, height: webHeight),
            configuration: webConfig
        )
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        
        // Desktop user agent for full site compatibility
        webView.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        
        // 3. Map WebView layer to SceneKit material
        let material = SCNMaterial()
        material.diffuse.contents = webView
        material.isDoubleSided = true
        material.lightingModel = .constant
        plane.materials = [material]
        
        // 4. Load the OS HTML
        let osHTML = VRMonitorNode.generateOSHTML()
        webView.loadHTMLString(osHTML, baseURL: nil)
        
        // 5. Add to UIKit view hierarchy (required for WKWebView to render on iOS 14+)
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first else { return }
            self.webView.frame = CGRect(x: 0, y: 0, width: webWidth, height: webHeight)
            self.webView.alpha = 0.01 // invisible to user but keeps GPU backing store alive
            self.webView.isUserInteractionEnabled = false
            window.addSubview(self.webView)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func cleanup() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }
    
    // MARK: - Interaction
    
    /// Simulate a click at the given UV coordinate (0-1 range)
    func simulateClick(at uv: CGPoint) {
        let js = """
            (function() {
                var cssX = \(uv.x) * window.innerWidth;
                var cssY = \(uv.y) * window.innerHeight;
                var el = document.elementFromPoint(cssX, cssY);
                
                if(el) {
                    // Visual feedback
                    var dot = document.createElement('div');
                    dot.style.cssText = 'position:fixed;left:'+(cssX-4)+'px;top:'+(cssY-4)+'px;width:8px;height:8px;background:cyan;border-radius:50%;z-index:999999;pointer-events:none;opacity:0.8;';
                    document.body.appendChild(dot);
                    setTimeout(function(){dot.remove()},400);
                    
                    // Fire full event sequence
                    var opts = {bubbles:true, cancelable:true, view:window, clientX:cssX, clientY:cssY};
                    el.dispatchEvent(new PointerEvent('pointerdown', Object.assign({}, opts, {pointerType:'touch'})));
                    el.dispatchEvent(new PointerEvent('pointerup', Object.assign({}, opts, {pointerType:'touch'})));
                    el.dispatchEvent(new MouseEvent('click', opts));
                    if(typeof el.click === 'function') el.click();
                }
            })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
    
    /// Scroll the active content area
    func simulateScroll(by delta: CGFloat) {
        let pixels = delta * 600
        let js = """
            (function() {
                var iframe = document.getElementById('browser-frame');
                if(iframe && iframe.style.display !== 'none') {
                    // Can't scroll cross-origin iframe from parent, so scroll the wrapper
                    iframe.contentWindow.postMessage({type:'scroll', delta:\(pixels)}, '*');
                } else {
                    var content = document.getElementById('active-content');
                    if(content) content.scrollTop += \(pixels);
                }
            })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
    
    // MARK: - WKScriptMessageHandler
    
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        
        switch action {
        case "navigate":
            if let urlStr = body["url"] as? String, let url = URL(string: urlStr) {
                onNavigate?(url)
            }
        default:
            break
        }
    }
    
    // MARK: - Visual Polish
    
    private func addBorderFrame(width: CGFloat, height: CGFloat) {
        let borderPlane = SCNPlane(width: width + 0.03, height: height + 0.03)
        borderPlane.cornerRadius = 0.05
        
        let borderMaterial = SCNMaterial()
        borderMaterial.diffuse.contents = UIColor.white.withAlphaComponent(0.08)
        borderMaterial.emission.contents = UIColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 0.4)
        borderMaterial.lightingModel = .constant
        borderMaterial.isDoubleSided = true
        borderPlane.materials = [borderMaterial]
        
        let borderNode = SCNNode(geometry: borderPlane)
        borderNode.name = "monitor_border"
        borderNode.position = SCNVector3(0, 0, -0.002)
        addChildNode(borderNode)
    }
    
    // MARK: - OS HTML Generation
    
    private static func generateOSHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <title>MadhurVision OS</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            
            @font-face {
                font-family: 'System';
                src: local('-apple-system'), local('Helvetica Neue'), local('sans-serif');
            }
            
            body {
                font-family: -apple-system, 'Helvetica Neue', sans-serif;
                background: #0a0a0f;
                color: #fff;
                width: 100vw;
                height: 100vh;
                overflow: hidden;
                user-select: none;
                -webkit-user-select: none;
            }
            
            /* ===== LOADING SCREEN ===== */
            #loading-screen {
                position: fixed;
                inset: 0;
                background: rgba(10, 10, 20, 0.50);
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                z-index: 10000;
                transition: opacity 0.6s ease;
            }
            #loading-screen.hidden { opacity: 0; pointer-events: none; }
            
            .loading-title {
                font-size: 64px;
                font-weight: 700;
                letter-spacing: 3px;
                background: linear-gradient(135deg, #00d4ff, #7b2ff7, #ff6ec7);
                -webkit-background-clip: text;
                -webkit-text-fill-color: transparent;
                margin-bottom: 20px;
            }
            .loading-sub {
                font-size: 22px;
                color: rgba(255,255,255,0.5);
                margin-bottom: 40px;
            }
            .loading-bar-track {
                width: 300px;
                height: 4px;
                background: rgba(255,255,255,0.1);
                border-radius: 2px;
                overflow: hidden;
            }
            .loading-bar-fill {
                height: 100%;
                width: 0%;
                background: linear-gradient(90deg, #00d4ff, #7b2ff7);
                border-radius: 2px;
                animation: loadFill 2.5s ease-out forwards;
            }
            @keyframes loadFill {
                0% { width: 0%; }
                60% { width: 70%; }
                100% { width: 100%; }
            }
            
            /* ===== DESKTOP ===== */
            #desktop {
                display: none;
                width: 100%;
                height: 100%;
            }
            #desktop.visible { display: flex; }
            
            /* ===== DOCK (Left Sidebar) ===== */
            #dock {
                width: 72px;
                height: 100%;
                background: rgba(255,255,255,0.04);
                border-right: 1px solid rgba(255,255,255,0.08);
                display: flex;
                flex-direction: column;
                align-items: center;
                padding: 16px 0;
                gap: 8px;
                flex-shrink: 0;
            }
            
            .dock-icon {
                width: 52px;
                height: 52px;
                border-radius: 14px;
                display: flex;
                align-items: center;
                justify-content: center;
                font-size: 26px;
                cursor: pointer;
                transition: all 0.2s ease;
                background: rgba(255,255,255,0.06);
                border: 1px solid transparent;
            }
            .dock-icon:hover {
                background: rgba(255,255,255,0.12);
                transform: scale(1.08);
            }
            .dock-icon.active {
                background: rgba(0, 212, 255, 0.15);
                border-color: rgba(0, 212, 255, 0.4);
                box-shadow: 0 0 12px rgba(0, 212, 255, 0.2);
            }
            .dock-label {
                font-size: 9px;
                color: rgba(255,255,255,0.5);
                margin-top: 2px;
                text-align: center;
            }
            .dock-item {
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 2px;
            }
            .dock-spacer { flex: 1; }
            
            /* ===== MAIN CONTENT AREA ===== */
            #main-area {
                flex: 1;
                display: flex;
                flex-direction: column;
                overflow: hidden;
            }
            
            /* Top Bar */
            #top-bar {
                height: 36px;
                background: rgba(255,255,255,0.03);
                border-bottom: 1px solid rgba(255,255,255,0.06);
                display: flex;
                align-items: center;
                padding: 0 14px;
                gap: 10px;
                flex-shrink: 0;
            }
            .top-bar-title {
                font-size: 13px;
                font-weight: 600;
                color: rgba(255,255,255,0.7);
            }
            .top-bar-spacer { flex: 1; }
            .top-bar-clock {
                font-size: 12px;
                color: rgba(255,255,255,0.4);
                font-variant-numeric: tabular-nums;
            }
            
            /* URL Bar (only visible in browser mode) */
            #url-bar-container {
                display: none;
                height: 40px;
                background: rgba(255,255,255,0.03);
                border-bottom: 1px solid rgba(255,255,255,0.06);
                padding: 4px 14px;
                gap: 8px;
                align-items: center;
                flex-shrink: 0;
            }
            #url-bar-container.visible { display: flex; }
            
            .nav-btn {
                width: 30px;
                height: 30px;
                border-radius: 8px;
                background: rgba(255,255,255,0.06);
                border: none;
                color: rgba(255,255,255,0.6);
                font-size: 16px;
                cursor: pointer;
                display: flex;
                align-items: center;
                justify-content: center;
            }
            .nav-btn:hover { background: rgba(255,255,255,0.12); }
            
            #url-input {
                flex: 1;
                height: 30px;
                background: rgba(255,255,255,0.06);
                border: 1px solid rgba(255,255,255,0.1);
                border-radius: 8px;
                color: #fff;
                font-size: 13px;
                padding: 0 12px;
                outline: none;
            }
            #url-input:focus {
                border-color: rgba(0, 212, 255, 0.5);
                background: rgba(255,255,255,0.08);
            }
            
            /* Content Views */
            #active-content {
                flex: 1;
                overflow: hidden;
                position: relative;
            }
            
            .content-view {
                display: none;
                width: 100%;
                height: 100%;
                position: absolute;
                inset: 0;
            }
            .content-view.active { display: flex; flex-direction: column; }
            
            /* Browser iframe */
            #browser-frame {
                width: 100%;
                height: 100%;
                border: none;
                background: #fff;
            }
            
            /* Home Screen */
            #home-view {
                align-items: center;
                justify-content: center;
                gap: 24px;
            }
            #home-view .home-logo {
                font-size: 80px;
                font-weight: 700;
                background: linear-gradient(135deg, #00d4ff, #7b2ff7);
                -webkit-background-clip: text;
                -webkit-text-fill-color: transparent;
            }
            #home-view .home-subtitle {
                font-size: 18px;
                color: rgba(255,255,255,0.35);
            }
            
            /* Settings View */
            #settings-view {
                padding: 30px;
                overflow-y: auto;
                gap: 16px;
            }
            .settings-title {
                font-size: 28px;
                font-weight: 700;
                margin-bottom: 10px;
            }
            .settings-group {
                background: rgba(255,255,255,0.04);
                border-radius: 14px;
                padding: 16px 20px;
                border: 1px solid rgba(255,255,255,0.06);
            }
            .settings-group-title {
                font-size: 12px;
                text-transform: uppercase;
                letter-spacing: 1px;
                color: rgba(0, 212, 255, 0.7);
                margin-bottom: 14px;
            }
            .settings-row {
                display: flex;
                align-items: center;
                justify-content: space-between;
                padding: 10px 0;
                border-bottom: 1px solid rgba(255,255,255,0.04);
            }
            .settings-row:last-child { border-bottom: none; }
            .settings-row-label {
                font-size: 15px;
                color: rgba(255,255,255,0.8);
            }
            .settings-row-value {
                font-size: 14px;
                color: rgba(255,255,255,0.4);
            }
            
            /* ===== AIR KEYBOARD ===== */
            #vr-air-keyboard {
                position: fixed;
                bottom: -50%;
                left: 50%;
                transform: translateX(-50%);
                width: 88%;
                max-width: 900px;
                background: rgba(20, 20, 30, 0.96);
                backdrop-filter: blur(20px);
                border-radius: 18px 18px 0 0;
                padding: 14px;
                display: flex;
                flex-direction: column;
                gap: 8px;
                z-index: 50000;
                transition: bottom 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
                box-shadow: 0 -8px 40px rgba(0,0,0,0.6);
                border: 1px solid rgba(255,255,255,0.1);
                border-bottom: none;
            }
            #vr-air-keyboard.visible { bottom: 0; }
            
            .kb-row {
                display: flex;
                justify-content: center;
                gap: 6px;
            }
            .kb-key {
                background: rgba(255,255,255,0.12);
                border: 1px solid rgba(255,255,255,0.15);
                color: white;
                font-size: 18px;
                font-family: -apple-system, sans-serif;
                font-weight: 500;
                padding: 12px 0;
                flex: 1;
                border-radius: 8px;
                text-align: center;
                cursor: pointer;
                transition: all 0.1s;
            }
            .kb-key:hover { background: rgba(255,255,255,0.22); }
            .kb-key:active { background: rgba(255,255,255,0.35); transform: scale(0.95); }
            .kb-key.wide { flex: 1.5; }
            .kb-key.space { flex: 5; }
            .kb-key.shift { flex: 1.3; font-size: 16px; }
        </style>
        </head>
        <body>
        
        <!-- LOADING SCREEN -->
        <div id="loading-screen">
            <div class="loading-title">MadhurVision</div>
            <div class="loading-sub">Initializing VR Environment...</div>
            <div class="loading-bar-track">
                <div class="loading-bar-fill"></div>
            </div>
        </div>
        
        <!-- DESKTOP -->
        <div id="desktop">
            <!-- Left Dock -->
            <div id="dock">
                <div class="dock-item" onclick="switchApp('home')">
                    <div class="dock-icon active" id="dock-home" data-app="home">🏠</div>
                    <div class="dock-label">Home</div>
                </div>
                <div class="dock-item" onclick="switchApp('browser')">
                    <div class="dock-icon" id="dock-browser" data-app="browser">🌐</div>
                    <div class="dock-label">Browser</div>
                </div>
                <div class="dock-item" onclick="switchApp('settings')">
                    <div class="dock-icon" id="dock-settings" data-app="settings">⚙️</div>
                    <div class="dock-label">Settings</div>
                </div>
                <div class="dock-spacer"></div>
            </div>
            
            <!-- Main Content -->
            <div id="main-area">
                <!-- Top Bar -->
                <div id="top-bar">
                    <div class="top-bar-title" id="app-title">Home</div>
                    <div class="top-bar-spacer"></div>
                    <div class="top-bar-clock" id="clock">00:00</div>
                </div>
                
                <!-- URL Bar (Browser only) -->
                <div id="url-bar-container">
                    <button class="nav-btn" onclick="browserBack()">◀</button>
                    <button class="nav-btn" onclick="browserForward()">▶</button>
                    <button class="nav-btn" onclick="browserReload()">↻</button>
                    <input type="text" id="url-input" placeholder="Search Google or type a URL..." value="https://www.google.com">
                </div>
                
                <!-- Content Area -->
                <div id="active-content">
                    <!-- Home -->
                    <div class="content-view active" id="home-view">
                        <div class="home-logo">MV</div>
                        <div class="home-subtitle">Welcome to MadhurVision OS</div>
                    </div>
                    
                    <!-- Browser -->
                    <div class="content-view" id="browser-view">
                        <iframe id="browser-frame" src="about:blank" sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"></iframe>
                    </div>
                    
                    <!-- Settings -->
                    <div class="content-view" id="settings-view">
                        <div class="settings-title">⚙️ System Settings</div>
                        
                        <div class="settings-group">
                            <div class="settings-group-title">Display</div>
                            <div class="settings-row">
                                <span class="settings-row-label">☀️ Brightness</span>
                                <span class="settings-row-value">Auto</span>
                            </div>
                            <div class="settings-row">
                                <span class="settings-row-label">📐 Screen Size</span>
                                <span class="settings-row-value">12" Virtual</span>
                            </div>
                            <div class="settings-row">
                                <span class="settings-row-label">👁️ IPD Offset</span>
                                <span class="settings-row-value">65mm</span>
                            </div>
                        </div>
                        
                        <div class="settings-group">
                            <div class="settings-group-title">Input</div>
                            <div class="settings-row">
                                <span class="settings-row-label">🖐️ Hand Tracking</span>
                                <span class="settings-row-value">Enabled</span>
                            </div>
                            <div class="settings-row">
                                <span class="settings-row-label">🎯 Cursor Sensitivity</span>
                                <span class="settings-row-value">2.5x</span>
                            </div>
                            <div class="settings-row">
                                <span class="settings-row-label">🖱️ Mouse Input</span>
                                <span class="settings-row-value">Connected</span>
                            </div>
                        </div>
                        
                        <div class="settings-group">
                            <div class="settings-group-title">Audio</div>
                            <div class="settings-row">
                                <span class="settings-row-label">🔊 Volume</span>
                                <span class="settings-row-value">80%</span>
                            </div>
                            <div class="settings-row">
                                <span class="settings-row-label">🎧 Audio Output</span>
                                <span class="settings-row-value">Built-in Speaker</span>
                            </div>
                        </div>
                        
                        <div class="settings-group">
                            <div class="settings-group-title">System</div>
                            <div class="settings-row">
                                <span class="settings-row-label">📱 Device</span>
                                <span class="settings-row-value">iPhone + VR Box</span>
                            </div>
                            <div class="settings-row">
                                <span class="settings-row-label">🔋 Battery</span>
                                <span class="settings-row-value">--</span>
                            </div>
                            <div class="settings-row">
                                <span class="settings-row-label">ℹ️ Version</span>
                                <span class="settings-row-value">MadhurVision OS 1.0</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <!-- AIR KEYBOARD -->
        <div id="vr-air-keyboard">
        </div>
        
        <script>
        // ===== BOOT SEQUENCE =====
        setTimeout(function() {
            document.getElementById('loading-screen').classList.add('hidden');
            setTimeout(function() {
                document.getElementById('loading-screen').style.display = 'none';
                document.getElementById('desktop').classList.add('visible');
            }, 600);
        }, 2500);
        
        // ===== CLOCK =====
        function updateClock() {
            var now = new Date();
            var h = now.getHours().toString().padStart(2, '0');
            var m = now.getMinutes().toString().padStart(2, '0');
            document.getElementById('clock').textContent = h + ':' + m;
        }
        updateClock();
        setInterval(updateClock, 30000);
        
        // ===== APP SWITCHING =====
        var currentApp = 'home';
        
        function switchApp(app) {
            if (currentApp === app) return;
            currentApp = app;
            
            // Update dock active states
            document.querySelectorAll('.dock-icon').forEach(function(icon) {
                icon.classList.remove('active');
            });
            var activeIcon = document.getElementById('dock-' + app);
            if (activeIcon) activeIcon.classList.add('active');
            
            // Update title
            var titles = { home: 'Home', browser: 'Browser', settings: 'Settings' };
            document.getElementById('app-title').textContent = titles[app] || app;
            
            // Show/hide URL bar
            var urlBar = document.getElementById('url-bar-container');
            if (app === 'browser') {
                urlBar.classList.add('visible');
            } else {
                urlBar.classList.remove('visible');
            }
            
            // Switch content views
            document.querySelectorAll('.content-view').forEach(function(v) {
                v.classList.remove('active');
            });
            var targetView = document.getElementById(app + '-view');
            if (targetView) targetView.classList.add('active');
            
            // Auto-load browser on first switch
            if (app === 'browser') {
                var iframe = document.getElementById('browser-frame');
                if (!iframe.src || iframe.src === 'about:blank') {
                    navigateTo('https://www.google.com');
                }
            }
        }
        
        // ===== BROWSER NAVIGATION =====
        function navigateTo(url) {
            if (!url.startsWith('http://') && !url.startsWith('https://')) {
                // Treat as a Google search
                url = 'https://www.google.com/search?q=' + encodeURIComponent(url);
            }
            document.getElementById('browser-frame').src = url;
            document.getElementById('url-input').value = url;
        }
        
        function browserBack() {
            try { document.getElementById('browser-frame').contentWindow.history.back(); } catch(e) {}
        }
        function browserForward() {
            try { document.getElementById('browser-frame').contentWindow.history.forward(); } catch(e) {}
        }
        function browserReload() {
            var iframe = document.getElementById('browser-frame');
            iframe.src = iframe.src;
        }
        
        // URL bar submission
        document.getElementById('url-input').addEventListener('keydown', function(e) {
            if (e.key === 'Enter') {
                e.preventDefault();
                navigateTo(this.value);
                this.blur();
            }
        });
        
        // ===== AIR KEYBOARD =====
        var kbContainer = document.getElementById('vr-air-keyboard');
        var isShifted = false;
        
        var layout = [
            ['1','2','3','4','5','6','7','8','9','0'],
            ['Q','W','E','R','T','Y','U','I','O','P'],
            ['A','S','D','F','G','H','J','K','L'],
            ['SHIFT','Z','X','C','V','B','N','M','DEL'],
            ['@','.com','SPACE','.','GO']
        ];
        
        layout.forEach(function(row) {
            var rowDiv = document.createElement('div');
            rowDiv.className = 'kb-row';
            row.forEach(function(key) {
                var btn = document.createElement('div');
                btn.className = 'kb-key';
                if (key === 'SPACE') { btn.classList.add('space'); btn.textContent = '⎵'; }
                else if (key === 'DEL') { btn.classList.add('wide'); btn.textContent = '⌫'; }
                else if (key === 'SHIFT') { btn.classList.add('shift'); btn.textContent = '⇧'; }
                else if (key === 'GO') { btn.classList.add('wide'); btn.textContent = 'GO'; }
                else if (key === '.com') { btn.classList.add('wide'); btn.textContent = '.com'; }
                else { btn.textContent = key; }
                
                btn.addEventListener('mousedown', function(e) { e.preventDefault(); });
                btn.addEventListener('click', function(e) {
                    e.preventDefault();
                    e.stopPropagation();
                    handleKey(key);
                });
                rowDiv.appendChild(btn);
            });
            kbContainer.appendChild(rowDiv);
        });
        
        function handleKey(key) {
            var el = document.activeElement;
            if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) return;
            
            if (key === 'DEL') {
                el.value = el.value.slice(0, -1);
            } else if (key === 'SPACE') {
                el.value += ' ';
            } else if (key === 'SHIFT') {
                isShifted = !isShifted;
                return;
            } else if (key === 'GO') {
                if (el.id === 'url-input') {
                    navigateTo(el.value);
                } else if (el.form) {
                    el.form.submit();
                }
                el.blur();
                return;
            } else if (key === '.com') {
                el.value += '.com';
            } else if (key === '@') {
                el.value += '@';
            } else if (key === '.') {
                el.value += '.';
            } else {
                el.value += isShifted ? key.toUpperCase() : key.toLowerCase();
                isShifted = false;
            }
            
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        
        // Show/Hide keyboard on focus
        document.addEventListener('focusin', function(e) {
            if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') {
                document.getElementById('vr-air-keyboard').classList.add('visible');
            }
        });
        document.addEventListener('focusout', function(e) {
            setTimeout(function() {
                document.getElementById('vr-air-keyboard').classList.remove('visible');
            }, 200);
        });
        
        // Prevent keyboard mousedown from stealing focus
        kbContainer.addEventListener('mousedown', function(e) { e.preventDefault(); });
        
        </script>
        </body>
        </html>
        """
    }
}
