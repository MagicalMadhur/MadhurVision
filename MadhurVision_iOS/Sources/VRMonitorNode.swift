import SceneKit
import WebKit
import UIKit

/// A single unified floating monitor in VR space.
/// Uses snapshot-based rendering for 100% reliable texture capture.
/// Navigates the WKWebView directly (no iframes) to avoid cross-origin issues.
class VRMonitorNode: SCNNode, WKScriptMessageHandler, WKNavigationDelegate {
    
    private var webView: WKWebView!
    private let monitorWidth: CGFloat
    private let monitorHeight: CGFloat
    private var snapshotTimer: Timer?
    private var isShowingOS = true // true = OS HTML, false = external website
    
    // Store the OS HTML so we can reload it when returning from browser
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
        
        addBorderFrame(width: width, height: height)
        
        // 2. Initialize WKWebView
        let resolutionMultiplier: CGFloat = 500
        let webWidth = width * resolutionMultiplier
        let webHeight = height * resolutionMultiplier
        
        let webConfig = WKWebViewConfiguration()
        webConfig.allowsInlineMediaPlayback = true
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        
        // JS → Swift bridge
        webConfig.userContentController.add(self, name: "vrOS")
        
        // Inject the floating dock overlay on EVERY page (including external sites)
        let dockOverlayScript = WKUserScript(
            source: VRMonitorNode.floatingDockJS(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webConfig.userContentController.addUserScript(dockOverlayScript)
        
        // Inject air keyboard on every page
        let keyboardScript = WKUserScript(
            source: VRMonitorNode.airKeyboardJS(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webConfig.userContentController.addUserScript(keyboardScript)
        
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: webWidth, height: webHeight),
            configuration: webConfig
        )
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.navigationDelegate = self
        
        // iPad user agent for desktop-class layout
        webView.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        
        // 3. Set up the material with a placeholder color (will be replaced by snapshots)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.black
        material.isDoubleSided = true
        material.lightingModel = .constant
        plane.materials = [material]
        
        // 4. Load OS HTML
        let osHTML = VRMonitorNode.generateOSHTML()
        VRMonitorNode.cachedOSHTML = osHTML
        webView.loadHTMLString(osHTML, baseURL: nil)
        
        // 5. Add to UIKit view hierarchy (needed for WKWebView to actually render)
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first else { return }
            self.webView.frame = CGRect(x: 0, y: 0, width: webWidth, height: webHeight)
            self.webView.alpha = 0.01
            self.webView.isUserInteractionEnabled = false
            window.addSubview(self.webView)
            
            // 6. Start snapshot-based rendering AFTER webView is in hierarchy
            self.startSnapshotCapture()
        }
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
    
    // MARK: - Snapshot-Based Rendering (THE FIX)
    
    private func startSnapshotCapture() {
        // Wait a moment for the HTML to render before first snapshot
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.captureSnapshot() // immediate first capture
        }
        
        // Then capture at ~15 FPS
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.captureSnapshot()
        }
    }
    
    private func captureSnapshot() {
        guard let webView = self.webView else { return }
        
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        
        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self = self, let image = image else { return }
            DispatchQueue.main.async {
                self.geometry?.firstMaterial?.diffuse.contents = image
            }
        }
    }
    
    // MARK: - Interaction
    
    func simulateClick(at uv: CGPoint) {
        let js = """
            (function() {
                var cssX = \(uv.x) * window.innerWidth;
                var cssY = \(uv.y) * window.innerHeight;
                var el = document.elementFromPoint(cssX, cssY);
                
                if(el) {
                    // Visual feedback dot
                    var dot = document.createElement('div');
                    dot.style.cssText = 'position:fixed;left:'+(cssX-4)+'px;top:'+(cssY-4)+'px;width:8px;height:8px;background:cyan;border-radius:50%;z-index:999999;pointer-events:none;opacity:0.8;';
                    document.body.appendChild(dot);
                    setTimeout(function(){dot.remove()},400);
                    
                    // Full event sequence for maximum compatibility
                    var opts = {bubbles:true, cancelable:true, view:window, clientX:cssX, clientY:cssY};
                    el.dispatchEvent(new PointerEvent('pointerdown', Object.assign({}, opts, {pointerType:'touch'})));
                    el.dispatchEvent(new PointerEvent('pointerup', Object.assign({}, opts, {pointerType:'touch'})));
                    el.dispatchEvent(new MouseEvent('click', opts));
                    if(typeof el.click === 'function') el.click();
                    
                    // Focus inputs for keyboard
                    if(el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                        el.focus();
                    }
                }
            })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
    
    func simulateScroll(by delta: CGFloat) {
        let pixels = delta * 600
        let js = "window.scrollBy(0, \(pixels));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
    
    // MARK: - Navigation (Direct, no iframes)
    
    /// Navigate to an external URL (browser mode)
    func navigateTo(url: URL) {
        isShowingOS = false
        webView?.load(URLRequest(url: url))
    }
    
    /// Go back to the OS home screen
    func goHome() {
        isShowingOS = true
        if let html = VRMonitorNode.cachedOSHTML {
            webView?.loadHTMLString(html, baseURL: nil)
        }
    }
    
    func goBack() {
        webView?.goBack()
    }
    
    func goForward() {
        webView?.goForward()
    }
    
    func reload() {
        webView?.reload()
    }
    
    // MARK: - WKScriptMessageHandler
    
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        
        switch action {
        case "navigate":
            if let urlStr = body["url"] as? String {
                var finalURL = urlStr
                if !finalURL.hasPrefix("http://") && !finalURL.hasPrefix("https://") {
                    finalURL = "https://www.google.com/search?q=" + (finalURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? finalURL)
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
        default:
            break
        }
    }
    
    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // After any page loads, take a snapshot immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.captureSnapshot()
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
    
    // MARK: - Floating Dock Overlay (injected on external websites)
    
    private static func floatingDockJS() -> String {
        return """
        (function() {
            // Don't inject on our own OS HTML
            if (document.getElementById('loading-screen') || document.getElementById('desktop')) return;
            
            // Don't double-inject
            if (document.getElementById('vr-floating-dock')) return;
            
            var dock = document.createElement('div');
            dock.id = 'vr-floating-dock';
            dock.innerHTML = '<div class="vfd-btn" id="vfd-home">🏠</div><div class="vfd-btn" id="vfd-back">◀</div><div class="vfd-btn" id="vfd-fwd">▶</div><div class="vfd-btn" id="vfd-reload">↻</div>';
            
            var style = document.createElement('style');
            style.textContent = `
                #vr-floating-dock {
                    position: fixed;
                    left: 8px;
                    top: 50%;
                    transform: translateY(-50%);
                    display: flex;
                    flex-direction: column;
                    gap: 6px;
                    z-index: 2147483647;
                    pointer-events: auto;
                }
                .vfd-btn {
                    width: 40px;
                    height: 40px;
                    background: rgba(0,0,0,0.7);
                    border: 1px solid rgba(255,255,255,0.2);
                    border-radius: 10px;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-size: 18px;
                    cursor: pointer;
                    color: white;
                }
                .vfd-btn:hover { background: rgba(0,0,0,0.9); }
            `;
            document.head.appendChild(style);
            document.body.appendChild(dock);
            
            document.getElementById('vfd-home').addEventListener('click', function() {
                window.webkit.messageHandlers.vrOS.postMessage({action:'goHome'});
            });
            document.getElementById('vfd-back').addEventListener('click', function() {
                window.webkit.messageHandlers.vrOS.postMessage({action:'goBack'});
            });
            document.getElementById('vfd-fwd').addEventListener('click', function() {
                window.webkit.messageHandlers.vrOS.postMessage({action:'goForward'});
            });
            document.getElementById('vfd-reload').addEventListener('click', function() {
                window.webkit.messageHandlers.vrOS.postMessage({action:'reload'});
            });
        })();
        """
    }
    
    // MARK: - Air Keyboard JS (injected on every page)
    
    private static func airKeyboardJS() -> String {
        return """
        (function() {
            if (document.getElementById('vr-air-keyboard')) return;
            
            var style = document.createElement('style');
            style.textContent = `
                #vr-air-keyboard {
                    position: fixed;
                    bottom: -50%;
                    left: 50%;
                    transform: translateX(-50%);
                    width: 88%;
                    max-width: 900px;
                    background: rgba(20, 20, 30, 0.96);
                    border-radius: 16px 16px 0 0;
                    padding: 12px;
                    display: flex;
                    flex-direction: column;
                    gap: 6px;
                    z-index: 2147483646;
                    transition: bottom 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
                    box-shadow: 0 -8px 40px rgba(0,0,0,0.6);
                    border: 1px solid rgba(255,255,255,0.1);
                    border-bottom: none;
                }
                #vr-air-keyboard.visible { bottom: 0; }
                .kb-row { display:flex; justify-content:center; gap:5px; }
                .kb-key {
                    background: rgba(255,255,255,0.12);
                    border: 1px solid rgba(255,255,255,0.15);
                    color: white;
                    font-size: 16px;
                    font-family: -apple-system, sans-serif;
                    font-weight: 500;
                    padding: 10px 0;
                    flex: 1;
                    border-radius: 7px;
                    text-align: center;
                    cursor: pointer;
                }
                .kb-key:active { background: rgba(255,255,255,0.35); transform: scale(0.95); }
                .kb-key.wide { flex: 1.5; }
                .kb-key.space { flex: 5; }
            `;
            document.head.appendChild(style);
            
            var kb = document.createElement('div');
            kb.id = 'vr-air-keyboard';
            
            var layout = [
                ['1','2','3','4','5','6','7','8','9','0'],
                ['Q','W','E','R','T','Y','U','I','O','P'],
                ['A','S','D','F','G','H','J','K','L'],
                ['Z','X','C','V','B','N','M','DEL'],
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
                    else if (key === 'GO') { btn.classList.add('wide'); btn.textContent = 'GO'; }
                    else if (key === '.com') { btn.classList.add('wide'); btn.textContent = '.com'; }
                    else { btn.textContent = key; }
                    
                    btn.addEventListener('mousedown', function(e) { e.preventDefault(); });
                    btn.addEventListener('click', function(e) {
                        e.preventDefault();
                        e.stopPropagation();
                        var el = document.activeElement;
                        if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) return;
                        if (key === 'DEL') { el.value = el.value.slice(0, -1); }
                        else if (key === 'SPACE') { el.value += ' '; }
                        else if (key === 'GO') {
                            if (el.form) { el.form.submit(); }
                            el.blur();
                            return;
                        }
                        else if (key === '.com') { el.value += '.com'; }
                        else if (key === '@') { el.value += '@'; }
                        else if (key === '.') { el.value += '.'; }
                        else { el.value += key.toLowerCase(); }
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                    });
                    rowDiv.appendChild(btn);
                });
                kb.appendChild(rowDiv);
            });
            
            document.body.appendChild(kb);
            kb.addEventListener('mousedown', function(e) { e.preventDefault(); });
            
            document.addEventListener('focusin', function(e) {
                if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') {
                    document.getElementById('vr-air-keyboard').classList.add('visible');
                }
            });
            document.addEventListener('focusout', function(e) {
                setTimeout(function() {
                    var kb = document.getElementById('vr-air-keyboard');
                    if (kb) kb.classList.remove('visible');
                }, 200);
            });
        })();
        """
    }
    
    // MARK: - OS HTML
    
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
                width: 300px; height: 4px;
                background: rgba(255,255,255,0.1);
                border-radius: 2px; overflow: hidden;
            }
            .loading-bar-fill {
                height: 100%; width: 0%;
                background: linear-gradient(90deg, #00d4ff, #7b2ff7);
                border-radius: 2px;
                animation: loadFill 2.5s ease-out forwards;
            }
            @keyframes loadFill { 0%{width:0%} 60%{width:70%} 100%{width:100%} }
            
            /* ===== DESKTOP ===== */
            #desktop {
                display: none; width: 100%; height: 100%;
            }
            #desktop.visible { display: flex; }
            
            /* Dock */
            #dock {
                width: 72px; height: 100%;
                background: rgba(255,255,255,0.04);
                border-right: 1px solid rgba(255,255,255,0.08);
                display: flex; flex-direction: column;
                align-items: center; padding: 16px 0; gap: 8px;
                flex-shrink: 0;
            }
            .dock-item { display:flex; flex-direction:column; align-items:center; gap:2px; }
            .dock-icon {
                width: 52px; height: 52px; border-radius: 14px;
                display: flex; align-items: center; justify-content: center;
                font-size: 26px; cursor: pointer;
                background: rgba(255,255,255,0.06);
                border: 1px solid transparent;
                transition: all 0.2s ease;
            }
            .dock-icon:hover { background: rgba(255,255,255,0.12); transform: scale(1.08); }
            .dock-icon.active {
                background: rgba(0,212,255,0.15);
                border-color: rgba(0,212,255,0.4);
                box-shadow: 0 0 12px rgba(0,212,255,0.2);
            }
            .dock-label { font-size: 9px; color: rgba(255,255,255,0.5); text-align: center; }
            .dock-spacer { flex: 1; }
            
            /* Main Area */
            #main-area { flex:1; display:flex; flex-direction:column; overflow:hidden; }
            
            /* Top Bar */
            #top-bar {
                height: 36px;
                background: rgba(255,255,255,0.03);
                border-bottom: 1px solid rgba(255,255,255,0.06);
                display: flex; align-items: center; padding: 0 14px; gap: 10px;
                flex-shrink: 0;
            }
            .top-bar-title { font-size:13px; font-weight:600; color:rgba(255,255,255,0.7); }
            .top-bar-spacer { flex:1; }
            .top-bar-clock { font-size:12px; color:rgba(255,255,255,0.4); font-variant-numeric:tabular-nums; }
            
            /* URL Bar */
            #url-bar-container {
                display: none; height: 40px;
                background: rgba(255,255,255,0.03);
                border-bottom: 1px solid rgba(255,255,255,0.06);
                padding: 4px 14px; gap: 8px; align-items: center; flex-shrink: 0;
            }
            #url-bar-container.visible { display: flex; }
            .nav-btn {
                width:30px; height:30px; border-radius:8px;
                background: rgba(255,255,255,0.06); border:none;
                color: rgba(255,255,255,0.6); font-size:16px; cursor:pointer;
                display:flex; align-items:center; justify-content:center;
            }
            .nav-btn:hover { background: rgba(255,255,255,0.12); }
            #url-input {
                flex:1; height:30px; background:rgba(255,255,255,0.06);
                border:1px solid rgba(255,255,255,0.1); border-radius:8px;
                color:#fff; font-size:13px; padding:0 12px; outline:none;
            }
            #url-input:focus { border-color:rgba(0,212,255,0.5); background:rgba(255,255,255,0.08); }
            
            /* Content */
            #active-content { flex:1; overflow:hidden; position:relative; }
            .content-view { display:none; width:100%; height:100%; position:absolute; inset:0; }
            .content-view.active { display:flex; flex-direction:column; }
            
            /* Home */
            #home-view { align-items:center; justify-content:center; gap:24px; }
            #home-view .home-logo {
                font-size:80px; font-weight:700;
                background: linear-gradient(135deg, #00d4ff, #7b2ff7);
                -webkit-background-clip:text; -webkit-text-fill-color:transparent;
            }
            #home-view .home-subtitle { font-size:18px; color:rgba(255,255,255,0.35); }
            
            /* Browser placeholder */
            #browser-view { align-items:center; justify-content:center; gap:20px; }
            #browser-view .browser-msg {
                font-size: 20px; color: rgba(255,255,255,0.6); text-align: center;
            }
            
            /* Settings */
            #settings-view { padding:30px; overflow-y:auto; gap:16px; }
            .settings-title { font-size:28px; font-weight:700; margin-bottom:10px; }
            .settings-group {
                background:rgba(255,255,255,0.04); border-radius:14px;
                padding:16px 20px; border:1px solid rgba(255,255,255,0.06);
            }
            .settings-group-title {
                font-size:12px; text-transform:uppercase; letter-spacing:1px;
                color:rgba(0,212,255,0.7); margin-bottom:14px;
            }
            .settings-row {
                display:flex; align-items:center; justify-content:space-between;
                padding:10px 0; border-bottom:1px solid rgba(255,255,255,0.04);
            }
            .settings-row:last-child { border-bottom:none; }
            .settings-row-label { font-size:15px; color:rgba(255,255,255,0.8); }
            .settings-row-value { font-size:14px; color:rgba(255,255,255,0.4); }
        </style>
        </head>
        <body>
        
        <!-- LOADING SCREEN -->
        <div id="loading-screen">
            <div class="loading-title">MadhurVision</div>
            <div class="loading-sub">Initializing VR Environment...</div>
            <div class="loading-bar-track"><div class="loading-bar-fill"></div></div>
        </div>
        
        <!-- DESKTOP -->
        <div id="desktop">
            <div id="dock">
                <div class="dock-item" onclick="switchApp('home')">
                    <div class="dock-icon active" id="dock-home">🏠</div>
                    <div class="dock-label">Home</div>
                </div>
                <div class="dock-item" onclick="switchApp('browser')">
                    <div class="dock-icon" id="dock-browser">🌐</div>
                    <div class="dock-label">Browser</div>
                </div>
                <div class="dock-item" onclick="switchApp('settings')">
                    <div class="dock-icon" id="dock-settings">⚙️</div>
                    <div class="dock-label">Settings</div>
                </div>
                <div class="dock-spacer"></div>
            </div>
            
            <div id="main-area">
                <div id="top-bar">
                    <div class="top-bar-title" id="app-title">Home</div>
                    <div class="top-bar-spacer"></div>
                    <div class="top-bar-clock" id="clock">00:00</div>
                </div>
                
                <div id="url-bar-container">
                    <button class="nav-btn" onclick="wkMsg('goBack')">◀</button>
                    <button class="nav-btn" onclick="wkMsg('goForward')">▶</button>
                    <button class="nav-btn" onclick="wkMsg('reload')">↻</button>
                    <input type="text" id="url-input" placeholder="Search Google or type a URL..." value="https://www.google.com">
                </div>
                
                <div id="active-content">
                    <div class="content-view active" id="home-view">
                        <div class="home-logo">MV</div>
                        <div class="home-subtitle">Welcome to MadhurVision OS</div>
                    </div>
                    <div class="content-view" id="browser-view">
                        <div class="browser-msg">Type a URL above and press GO to browse</div>
                    </div>
                    <div class="content-view" id="settings-view">
                        <div class="settings-title">⚙️ System Settings</div>
                        <div class="settings-group">
                            <div class="settings-group-title">Display</div>
                            <div class="settings-row"><span class="settings-row-label">☀️ Brightness</span><span class="settings-row-value">Auto</span></div>
                            <div class="settings-row"><span class="settings-row-label">📐 Screen Size</span><span class="settings-row-value">12" Virtual</span></div>
                            <div class="settings-row"><span class="settings-row-label">👁️ IPD Offset</span><span class="settings-row-value">65mm</span></div>
                        </div>
                        <div class="settings-group">
                            <div class="settings-group-title">Input</div>
                            <div class="settings-row"><span class="settings-row-label">🖐️ Hand Tracking</span><span class="settings-row-value">Enabled</span></div>
                            <div class="settings-row"><span class="settings-row-label">🎯 Cursor Sensitivity</span><span class="settings-row-value">2.5x</span></div>
                            <div class="settings-row"><span class="settings-row-label">🖱️ Mouse Input</span><span class="settings-row-value">Connected</span></div>
                        </div>
                        <div class="settings-group">
                            <div class="settings-group-title">Audio</div>
                            <div class="settings-row"><span class="settings-row-label">🔊 Volume</span><span class="settings-row-value">80%</span></div>
                            <div class="settings-row"><span class="settings-row-label">🎧 Audio Output</span><span class="settings-row-value">Built-in Speaker</span></div>
                        </div>
                        <div class="settings-group">
                            <div class="settings-group-title">System</div>
                            <div class="settings-row"><span class="settings-row-label">📱 Device</span><span class="settings-row-value">iPhone + VR Box</span></div>
                            <div class="settings-row"><span class="settings-row-label">ℹ️ Version</span><span class="settings-row-value">MadhurVision OS 1.0</span></div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <script>
        // Boot sequence
        setTimeout(function() {
            document.getElementById('loading-screen').classList.add('hidden');
            setTimeout(function() {
                document.getElementById('loading-screen').style.display = 'none';
                document.getElementById('desktop').classList.add('visible');
            }, 600);
        }, 2500);
        
        // Clock
        function updateClock() {
            var now = new Date();
            document.getElementById('clock').textContent =
                now.getHours().toString().padStart(2,'0') + ':' + now.getMinutes().toString().padStart(2,'0');
        }
        updateClock(); setInterval(updateClock, 30000);
        
        // Swift bridge helper
        function wkMsg(action, data) {
            var msg = {action: action};
            if (data) Object.assign(msg, data);
            window.webkit.messageHandlers.vrOS.postMessage(msg);
        }
        
        // App switching
        var currentApp = 'home';
        function switchApp(app) {
            if (currentApp === app) return;
            currentApp = app;
            
            document.querySelectorAll('.dock-icon').forEach(function(i) { i.classList.remove('active'); });
            var di = document.getElementById('dock-' + app);
            if (di) di.classList.add('active');
            
            var titles = {home:'Home', browser:'Browser', settings:'Settings'};
            document.getElementById('app-title').textContent = titles[app] || app;
            
            var urlBar = document.getElementById('url-bar-container');
            urlBar.classList.toggle('visible', app === 'browser');
            
            document.querySelectorAll('.content-view').forEach(function(v) { v.classList.remove('active'); });
            var target = document.getElementById(app + '-view');
            if (target) target.classList.add('active');
        }
        
        // URL bar
        document.getElementById('url-input').addEventListener('keydown', function(e) {
            if (e.key === 'Enter') {
                e.preventDefault();
                wkMsg('navigate', {url: this.value});
            }
        });
        </script>
        </body>
        </html>
        """
    }
}
