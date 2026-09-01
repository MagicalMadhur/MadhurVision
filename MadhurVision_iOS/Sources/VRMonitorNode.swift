import SceneKit
import UIKit
import AVFoundation
import SpriteKit
import WebKit

/// Native Spatial Video Item Model
public struct SpatialVideoItem: Identifiable {
    public let id: String
    public let title: String
    public let channel: String
    public let category: String
    public let duration: String
    public let streamURL: String
    public let icon: String
    public let gradientColors: [UIColor]
}

/// Pure Native Spatial OS for VR Monitor (Native Apps + Direct Cinema + Web Engine)
public final class VRMonitorNode: SCNNode, WKNavigationDelegate, WKUIDelegate {
    
    // MARK: - Canvas Dimensions
    public static let canvasWidth: CGFloat = 1440
    public static let canvasHeight: CGFloat = 810
    
    public let monitorWidth: CGFloat
    public let monitorHeight: CGFloat
    
    // MARK: - State Machine
    public enum SpatialViewState {
        case home
        case webBrowser(url: String, title: String)
        case cinemaTheater(item: SpatialVideoItem)
        case youtubeFeed
        case settings
    }
    
    public private(set) var currentState: SpatialViewState = .home
    public var selectedCategory: String = "All"
    
    // MARK: - Web Browser Engine
    private var webView: WKWebView?
    public private(set) var currentWebURL: String = ""
    public private(set) var currentWebTitle: String = ""
    private var isWebLoading: Bool = false
    private var webSnapshotTimer: Timer?
    private var isSnapshotting: Bool = false
    /// Caches the last successfully captured web snapshot so we can re-render it
    /// immediately whenever renderCurrentState() is called (e.g. after a dock tap).
    private var cachedWebSnapshot: UIImage? = nil
    
    // MARK: - Cinema Player Engine (Direct Metal GPU Texture)
    private var cinemaPlayer: AVPlayer?
    private var videoSKNode: SKVideoNode?
    private var videoSKScene: SKScene?
    private var cinemaTimeObserver: Any?
    public private(set) var isCinemaMode: Bool = false
    public private(set) var currentVideoTitle: String = ""
    public private(set) var currentPlaybackSeconds: Double = 0.0
    public private(set) var totalDurationSeconds: Double = 0.0
    public private(set) var isMuted: Bool = false
    
    // MARK: - Settings & Callbacks
    public var onScaleChanged: ((CGFloat) -> Void)?
    public var onIPDChanged: ((Float) -> Void)?
    public var onRecalibrateRequested: (() -> Void)?
    public var onPassthroughToggled: ((Bool) -> Void)?
    public var onExitVRRequested: (() -> Void)?
    public var onSnapshotImage: ((UIImage) -> Void)?
    public var onLensOffsetChanged: ((CGFloat, Float) -> Void)?
    
    public var currentScale: CGFloat = 1.0
    public var currentIPD: Float = 0.063
    public var currentLensOffset: CGFloat = 34.0
    public var isPassthroughActive: Bool = false
    
    // MARK: - Curated High-Definition Spatial Video Catalog
    public let cinemaCatalog: [SpatialVideoItem] = [
        SpatialVideoItem(
            id: "nature_4k",
            title: "Earth 4K HDR • Breathtaking Wildlife & Forest Landscapes",
            channel: "BBC Earth Showcase",
            category: "Nature 4K",
            duration: "10:34",
            streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
            icon: "🌿",
            gradientColors: [UIColor(red: 0.05, green: 0.35, blue: 0.20, alpha: 1.0), UIColor(red: 0.02, green: 0.15, blue: 0.08, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "interstellar_imax",
            title: "Interstellar Cosmic Flight • Deep Space Sci-Fi Experience",
            channel: "Hans Zimmer IMAX",
            category: "Sci-Fi IMAX",
            duration: "12:14",
            streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4",
            icon: "🚀",
            gradientColors: [UIColor(red: 0.10, green: 0.15, blue: 0.45, alpha: 1.0), UIColor(red: 0.03, green: 0.05, blue: 0.20, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "lofi_beats",
            title: "Lofi Girl • 24/7 Relaxing Chill Beats to Code & Study in VR",
            channel: "Lofi Girl Records",
            category: "Music & Lo-Fi",
            duration: "LIVE",
            streamURL: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
            icon: "🎧",
            gradientColors: [UIColor(red: 0.40, green: 0.10, blue: 0.35, alpha: 1.0), UIColor(red: 0.15, green: 0.03, blue: 0.15, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "synthwave_cyber",
            title: "Cyberpunk Night Drive 4K • Retro Synthwave Chillout",
            channel: "Neon Cyberwave",
            category: "Music & Lo-Fi",
            duration: "08:45",
            streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
            icon: "🌆",
            gradientColors: [UIColor(red: 0.35, green: 0.05, blue: 0.45, alpha: 1.0), UIColor(red: 0.10, green: 0.02, blue: 0.20, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "sintel_epic",
            title: "Sintel 4K • Epic Dragon Fantasy Cinema Experience",
            channel: "Blender Open Cinema",
            category: "Animation & Movies",
            duration: "14:48",
            streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4",
            icon: "🐉",
            gradientColors: [UIColor(red: 0.45, green: 0.18, blue: 0.05, alpha: 1.0), UIColor(red: 0.20, green: 0.05, blue: 0.02, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "elephants_dream",
            title: "Elephants Dream 4K • Surreal Cybernetic Sci-Fi",
            channel: "Blender Studio",
            category: "Animation & Movies",
            duration: "10:54",
            streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4",
            icon: "🎞️",
            gradientColors: [UIColor(red: 0.30, green: 0.20, blue: 0.40, alpha: 1.0), UIColor(red: 0.10, green: 0.05, blue: 0.15, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "apple_hls",
            title: "Apple Adaptive Bitrate Spatial HLS Multi-Audio Stream",
            channel: "Apple Developer Streaming",
            category: "Apple & VR Tech",
            duration: "30:00",
            streamURL: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8",
            icon: "⚡",
            gradientColors: [UIColor(red: 0.05, green: 0.30, blue: 0.50, alpha: 1.0), UIColor(red: 0.02, green: 0.10, blue: 0.22, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "gaming_showcase",
            title: "Unreal Engine 5 Next-Gen Graphics & Raytracing Showcase",
            channel: "NextGen Gaming VR",
            category: "Gaming",
            duration: "09:12",
            streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4",
            icon: "🎮",
            gradientColors: [UIColor(red: 0.05, green: 0.25, blue: 0.40, alpha: 1.0), UIColor(red: 0.02, green: 0.08, blue: 0.15, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "ocean_4k",
            title: "Deep Blue Ocean 4K • Coral Reefs & Marine Life HDR",
            channel: "National Marine Showcase",
            category: "Nature 4K",
            duration: "15:20",
            streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4",
            icon: "🐋",
            gradientColors: [UIColor(red: 0.02, green: 0.25, blue: 0.45, alpha: 1.0), UIColor(red: 0.01, green: 0.08, blue: 0.20, alpha: 1.0)]
        )
    ]
    
    // MARK: - Interactive Hit Bounds Registry
    private struct ClickableZone {
        let rect: CGRect
        let action: () -> Void
    }
    private var activeClickableZones: [ClickableZone] = []
    
    // MARK: - Initializer
    public init(width: CGFloat = 2.4, height: CGFloat = 1.35) {
        self.monitorWidth = width
        self.monitorHeight = height
        super.init()
        
        // 1. Create physical 3D plane geometry
        let plane = SCNPlane(width: width, height: height)
        plane.cornerRadius = 0.04
        self.geometry = plane
        self.name = "vr_monitor"
        
        // 2. Add subtle glowing border frame
        addBorderFrame(width: width, height: height)
        
        // 3. INSTANT FRAME 0 RENDER: Draw native OS desktop immediately on millisecond 0!
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant
        plane.materials = [material]
        
        renderCurrentState()
        AppLogger.shared.log("[VRMonitorNode] Pure Native Spatial OS initialized with Direct Metal Engine!")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func cleanup() {
        stopWebSnapshotTimer()
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        cachedWebSnapshot = nil
        exitCinemaMode()
        activeClickableZones.removeAll()
    }
    
    // MARK: - UV Coordinates from 3D World Hit
    public func uvCoordinates(fromWorldPoint worldPoint: SCNVector3) -> CGPoint {
        let local = convertPosition(worldPoint, from: nil)
        let u = CGFloat(min(max((local.x / Float(monitorWidth)) + 0.5, 0.0), 1.0))
        let v = CGFloat(min(max(0.5 - (local.y / Float(monitorHeight)), 0.0), 1.0))
        return CGPoint(x: u, y: v)
    }
    
    // MARK: - Snapshot Application
    public func applySnapshot(_ image: UIImage) {
        guard !isCinemaMode else { return }
        geometry?.firstMaterial?.diffuse.contents = image
    }
    
    // MARK: - Native Click Dispatcher
    public func simulateClick(at uv: CGPoint) {
        let pixelX = uv.x * VRMonitorNode.canvasWidth
        let pixelY = uv.y * VRMonitorNode.canvasHeight
        let hitPoint = CGPoint(x: pixelX, y: pixelY)
        
        // 1. Check if clicked on Web Browser content
        if case .webBrowser = currentState {
            // Check top navigation bar zones (y <= 60) or sidebar dock (x <= 100)
            for zone in activeClickableZones {
                if zone.rect.contains(hitPoint) {
                    AppLogger.shared.log("[VRMonitorNode] Web Browser UI Click hit \(zone.rect)")
                    zone.action()
                    return
                }
            }
            
            // Dispatch synthetic touch, pointer, and click events into DOM in WKWebView
            if let webView = self.webView, pixelX > 100 && pixelY > 60 {
                let webX = pixelX - 100
                let webY = pixelY - 60
                let js = """
                (function() {
                    var x = \(webX);
                    var y = \(webY);
                    var el = document.elementFromPoint(x, y);
                    if (!el) return;
                    
                    // 1. Find closest clickable link or button
                    var anchor = el.closest('a') || el.closest('ytm-compact-video-renderer') || el.closest('ytm-video-with-context-renderer') || el.closest('ytm-media-item');
                    var button = el.closest('button') || el.closest('[role="button"]') || el.closest('[onclick]') || el.closest('ytm-pivot-bar-item-renderer') || el.closest('.ytm-searchbox');
                    var input = el.closest('input') || el.closest('textarea');
                    var target = input || anchor || button || el;
                    
                    if (input) {
                        input.focus();
                    }
                    
                    // 2. Dispatch Touch Events
                    try {
                        var touch = new Touch({ identifier: Date.now(), target: target, clientX: x, clientY: y, screenX: x, screenY: y, pageX: x, pageY: y });
                        var tStart = new TouchEvent('touchstart', { cancelable: true, bubbles: true, touches: [touch], targetTouches: [touch], changedTouches: [touch] });
                        var tEnd = new TouchEvent('touchend', { cancelable: true, bubbles: true, touches: [], targetTouches: [], changedTouches: [touch] });
                        target.dispatchEvent(tStart);
                        target.dispatchEvent(tEnd);
                    } catch(e) {}
                    
                    // 3. Dispatch Pointer & Mouse Events
                    try {
                        var pDown = new PointerEvent('pointerdown', { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window });
                        var pUp = new PointerEvent('pointerup', { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window });
                        target.dispatchEvent(pDown);
                        target.dispatchEvent(pUp);
                        
                        var mDown = new MouseEvent('mousedown', { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window });
                        var mUp = new MouseEvent('mouseup', { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window });
                        var mClick = new MouseEvent('click', { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window });
                        target.dispatchEvent(mDown);
                        target.dispatchEvent(mUp);
                        target.dispatchEvent(mClick);
                    } catch(e) {}
                    
                    // 4. Trigger direct click method
                    if (typeof target.click === 'function') {
                        target.click();
                    }
                    
                    // 5. Direct navigation fallback for YouTube video cards
                    if (anchor && anchor.href && anchor.href.length > 0 && !anchor.href.startsWith('javascript:')) {
                        window.location.href = anchor.href;
                    }
                })();
                """
                webView.evaluateJavaScript(js, completionHandler: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.captureWebSnapshot()
                }
                return
            }
        }
        
        // 2. Check if in Cinema Mode and clicked on Timeline Scrub Bar
        if isCinemaMode {
            let trackRect = CGRect(x: 170, y: VRMonitorNode.canvasHeight - 90, width: VRMonitorNode.canvasWidth - 340, height: 35)
            if trackRect.contains(hitPoint) && totalDurationSeconds > 0 {
                let fraction = Double(max(0.0, min(1.0, (pixelX - 180) / (VRMonitorNode.canvasWidth - 360))))
                let targetSec = fraction * totalDurationSeconds
                self.seekCinemaTo(seconds: targetSec)
                AppLogger.shared.log("[VRMonitorNode] Scrubbed cinema timeline to \(targetSec)s (\(Int(fraction * 100))%)")
                return
            }
        }
        
        // 3. Check native clickable zones from top to bottom
        for zone in activeClickableZones {
            if zone.rect.contains(hitPoint) {
                AppLogger.shared.log("[VRMonitorNode] Native Click at (\(Int(pixelX)), \(Int(pixelY))) hit zone \(zone.rect)")
                zone.action()
                return
            }
        }
        
        AppLogger.shared.log("[VRMonitorNode] Native Click at (\(Int(pixelX)), \(Int(pixelY))) had no registered zone.")
    }
    
    public func simulateScroll(by delta: CGFloat) {
        if case .webBrowser = currentState, let webView = self.webView {
            let js = "window.scrollBy(0, \(delta * 80));"
            webView.evaluateJavaScript(js, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.captureWebSnapshot()
            }
        }
    }
    
    // MARK: - In-VR Web Browser Engine
    public func openWebURL(_ urlString: String, title: String = "Web Browser") {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if self.isCinemaMode {
                self.exitCinemaMode()
            }
            
            // Reset snapshot cache when navigating to a new URL so we show
            // the "loading" placeholder until a real frame arrives.
            self.cachedWebSnapshot = nil
            self.currentWebURL = urlString
            self.currentWebTitle = title
            self.isWebLoading = true
            self.currentState = .webBrowser(url: urlString, title: title)
            self.renderCurrentState()
            
            // Stop any previous snapshot timer while the new page loads
            self.stopWebSnapshotTimer()
            
            // Initialize WKWebView if not already created
            if self.webView == nil {
                let config = WKWebViewConfiguration()
                config.allowsInlineMediaPlayback = true
                config.mediaTypesRequiringUserActionForPlayback = []
                config.allowsAirPlayForMediaPlayback = true
                config.allowsPictureInPictureMediaPlayback = true
                
                let pref = WKWebpagePreferences()
                pref.allowsContentJavaScript = true
                config.defaultWebpagePreferences = pref
                
                // Process pool for cookie/session persistence
                config.processPool = WKProcessPool()
                
                // Use a realistic iPhone screen-sized frame. Placing at a large
                // negative x keeps it completely off-screen for the user while
                // letting WebKit fully composite the layer (alpha MUST be 1.0
                // or WebKit will skip drawing and takeSnapshot returns blank).
                let screenW = UIScreen.main.bounds.width
                let screenH = UIScreen.main.bounds.height
                let webRect = CGRect(x: -(screenW + 100), y: 0, width: screenW, height: screenH)
                let wv = WKWebView(frame: webRect, configuration: config)
                wv.navigationDelegate = self
                wv.uiDelegate = self
                wv.isOpaque = true
                wv.backgroundColor = .white
                wv.scrollView.bounces = false
                wv.scrollView.contentInsetAdjustmentBehavior = .never
                // Full alpha is mandatory — WebKit skips compositing for alpha < ~0.05,
                // causing takeSnapshot() to return a blank/white image.
                wv.alpha = 1.0
                wv.isUserInteractionEnabled = false
                wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
                
                // Attach to the live window hierarchy so WebKit's GPU compositor
                // runs (required for HTML5 video, JavaScript timers, etc.).
                if let windowScene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                   let window = windowScene.windows.first {
                    window.addSubview(wv)
                } else if let window = UIApplication.shared.windows.first {
                    // Fallback for older iOS / edge cases
                    window.addSubview(wv)
                }
                
                self.webView = wv
            }
            
            // Auto-redirect desktop youtube to fast mobile HTML5 youtube
            var targetURL = urlString
            if targetURL.contains("youtube.com") && !targetURL.contains("m.youtube.com") {
                targetURL = targetURL.replacingOccurrences(of: "www.youtube.com", with: "m.youtube.com")
                targetURL = targetURL.replacingOccurrences(of: "https://youtube.com", with: "https://m.youtube.com")
            }
            
            if let url = URL(string: targetURL) {
                let req = URLRequest(url: url)
                self.webView?.load(req)
            }
            
            // NOTE: Do NOT start the snapshot timer here. We start it inside
            // webView(_:didFinish:) once the page has actually rendered.
            // Starting it too early causes blank white frames to overwrite the
            // "Loading…" placeholder before any content is ready.
        }
    }
    
    private func startWebSnapshotTimer() {
        webSnapshotTimer?.invalidate()
        webSnapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.captureWebSnapshot()
        }
    }
    
    private func stopWebSnapshotTimer() {
        webSnapshotTimer?.invalidate()
        webSnapshotTimer = nil
    }
    
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isWebLoading = true
        renderCurrentState()
    }
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isWebLoading = false
        if let currentURL = webView.url?.absoluteString {
            self.currentWebURL = currentURL
        }
        
        // Force inline HTML5 video playback and auto-play for YouTube
        let inlineScript = """
        (function() {
            // Mark all videos as inline playback
            var videos = document.querySelectorAll('video');
            videos.forEach(function(v) {
                v.setAttribute('playsinline', 'true');
                v.setAttribute('webkit-playsinline', 'true');
                v.removeAttribute('controls');
                v.controls = true;
            });
            
            // Disable YouTube's fullscreen-only player override
            var meta = document.querySelector('meta[name="viewport"]');
            if (!meta) {
                meta = document.createElement('meta');
                meta.name = 'viewport';
                document.head.appendChild(meta);
            }
            meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
        })();
        """
        webView.evaluateJavaScript(inlineScript, completionHandler: nil)
        
        // Start the snapshot timer only AFTER the page has finished loading and
        // the WebKit compositor has rendered the first meaningful frame.
        self.startWebSnapshotTimer()
        
        // Capture immediately without waiting for the first timer tick
        self.captureWebSnapshot()
    }
    
    // Handle navigation failures gracefully
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isWebLoading = false
        captureWebSnapshot()
    }
    
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isWebLoading = false
        captureWebSnapshot()
    }
    
    // Allow all navigation (YouTube redirects between m.youtube.com pages)
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
    
    // Handle target="_blank" links (YouTube opens video pages with these)
    // Load them in the same webview instead of trying to open a new window
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
    
    public func captureWebSnapshot() {
        guard case .webBrowser = currentState, let webView = self.webView, !isSnapshotting else { return }
        isSnapshotting = true
        
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = true
        
        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self = self else { return }
            self.isSnapshotting = false
            
            // Cache the snapshot so renderCurrentState() can use it.
            // This ensures we always show the last valid frame.
            if let image = image {
                self.cachedWebSnapshot = image
            }
            
            // Trigger a full render pass so the 3D monitor texture updates
            // immediately whenever a new frame arrives.
            self.renderCurrentState()
        }
    }
    
    // MARK: - State Navigation
    public func setViewState(_ state: SpatialViewState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isCinemaMode {
                self.exitCinemaMode()
            }
            self.stopWebSnapshotTimer()
            
            // Clear the cached snapshot when leaving the web browser so the next
            // visit starts fresh with the loading placeholder.
            if case .webBrowser = self.currentState, !case .webBrowser = state {
                self.cachedWebSnapshot = nil
            }
            
            self.currentState = state
            self.renderCurrentState()
        }
    }
    
    public func goHome() {
        setViewState(.home)
    }
    
    public func goBack() {
        switch currentState {
        case .webBrowser:
            if let webView = self.webView, webView.canGoBack {
                webView.goBack()
            } else {
                goHome()
            }
        case .home:
            break
        default:
            goHome()
        }
    }
    
    public func goForward() {
        if case .webBrowser = currentState, let webView = self.webView, webView.canGoForward {
            webView.goForward()
        }
    }
    
    public func reload() {
        if case .webBrowser = currentState, let webView = self.webView {
            webView.reload()
        } else {
            renderCurrentState()
        }
    }
    
    // MARK: - Direct Metal GPU Video Cinema Engine
    public func startCinemaStream(item: SpatialVideoItem) {
        guard let url = URL(string: item.streamURL) else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.cinemaPlayer?.pause()
            if let obs = self.cinemaTimeObserver {
                self.cinemaPlayer?.removeTimeObserver(obs)
                self.cinemaTimeObserver = nil
            }
            self.videoSKNode?.removeFromParent()
            self.videoSKNode = nil
            self.videoSKScene = nil
            
            let playerItem = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: playerItem)
            player.actionAtItemEnd = .none
            self.cinemaPlayer = player
            self.isCinemaMode = true
            self.currentVideoTitle = item.title
            self.currentPlaybackSeconds = 0.0
            self.totalDurationSeconds = 0.0
            self.currentState = .cinemaTheater(item: item)
            
            // Create SpriteKit Video Texture for SceneKit (Zero-Copy Metal GPU Pipeline)
            let sceneSize = CGSize(width: VRMonitorNode.canvasWidth, height: VRMonitorNode.canvasHeight)
            let skScene = SKScene(size: sceneSize)
            skScene.backgroundColor = .black
            
            let videoNode = SKVideoNode(avPlayer: player)
            videoNode.size = sceneSize
            videoNode.position = CGPoint(x: sceneSize.width / 2.0, y: sceneSize.height / 2.0)
            videoNode.yScale = -1.0 // Coordinate alignment for SCNPlane texture mapping
            
            skScene.addChild(videoNode)
            self.setupCinemaHUDOverlay(on: skScene, item: item)
            self.videoSKScene = skScene
            self.videoSKNode = videoNode
            
            // Assign dynamic SpriteKit video texture to SCNMaterial
            self.geometry?.firstMaterial?.diffuse.contents = skScene
            videoNode.play()
            player.play()
            
            // Periodic time observer for interactive scrubbing & HUD updates
            let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
            self.cinemaTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self = self else { return }
                self.currentPlaybackSeconds = time.seconds
                if let dur = player.currentItem?.duration.seconds, !dur.isNaN && dur > 0 {
                    self.totalDurationSeconds = dur
                }
                self.updateCinemaHUDOverlay()
            }
            
            // Auto-restore Web OS desktop when video finishes playing or errors
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
                self?.exitCinemaMode()
            }
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
                self?.exitCinemaMode()
            }
            
            // Register Cinema HUD Click Zones (Top bar & controls overlay)
            self.registerCinemaClickZones(item: item)
            AppLogger.shared.log("[VRMonitorNode] Direct Metal GPU Video started for \(item.title): \(url.absoluteString)")
        }
    }
    
    public func exitCinemaMode() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.cinemaPlayer?.pause()
            if let obs = self.cinemaTimeObserver {
                self.cinemaPlayer?.removeTimeObserver(obs)
                self.cinemaTimeObserver = nil
            }
            self.cinemaPlayer = nil
            self.videoSKNode?.removeFromParent()
            self.videoSKNode = nil
            self.videoSKScene = nil
            self.isCinemaMode = false
            self.currentState = .youtubeFeed
            self.renderCurrentState()
        }
    }
    
    public func togglePlayPauseCinema() {
        guard let player = cinemaPlayer else { return }
        if player.rate > 0 {
            player.pause()
        } else {
            player.play()
        }
        updateCinemaHUDOverlay()
    }
    
    public func seekCinema(by seconds: Double) {
        guard let player = cinemaPlayer else { return }
        let current = player.currentTime()
        let target = CMTimeAdd(current, CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: target)
    }
    
    public func seekCinemaTo(seconds: Double) {
        guard let player = cinemaPlayer else { return }
        let target = CMTime(seconds: max(0.0, seconds), preferredTimescale: 600)
        player.seek(to: target)
    }
    
    public func toggleMuteCinema() {
        guard let player = cinemaPlayer else { return }
        isMuted.toggle()
        player.isMuted = isMuted
        updateCinemaHUDOverlay()
    }
    
    // MARK: - Cinema HUD In-VR SpriteKit Nodes
    private func setupCinemaHUDOverlay(on scene: SKScene, item: SpatialVideoItem) {
        // 1. Top HUD Container
        let topBar = SKShapeNode(rectOf: CGSize(width: VRMonitorNode.canvasWidth, height: 70), cornerRadius: 0)
        topBar.position = CGPoint(x: VRMonitorNode.canvasWidth / 2.0, y: VRMonitorNode.canvasHeight - 35)
        topBar.fillColor = UIColor(white: 0.05, alpha: 0.75)
        topBar.strokeColor = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.3)
        topBar.lineWidth = 1
        topBar.name = "hud_top_bar"
        topBar.yScale = -1.0 // Flip coordinate for SceneKit texture alignment
        
        let titleLabel = SKLabelNode(text: "\(item.icon)  \(item.title)")
        titleLabel.fontSize = 20
        titleLabel.fontName = "HelveticaNeue-Bold"
        titleLabel.fontColor = .white
        titleLabel.horizontalAlignmentMode = .left
        titleLabel.verticalAlignmentMode = .center
        titleLabel.position = CGPoint(x: -VRMonitorNode.canvasWidth / 2.0 + 30, y: 0)
        titleLabel.name = "hud_title_label"
        topBar.addChild(titleLabel)
        
        let closeBtn = SKShapeNode(rectOf: CGSize(width: 150, height: 42), cornerRadius: 10)
        closeBtn.fillColor = UIColor(red: 0.9, green: 0.15, blue: 0.25, alpha: 0.85)
        closeBtn.strokeColor = .clear
        closeBtn.position = CGPoint(x: VRMonitorNode.canvasWidth / 2.0 - 95, y: 0)
        
        let closeText = SKLabelNode(text: "✕ Exit Cinema")
        closeText.fontSize = 15
        closeText.fontName = "HelveticaNeue-Bold"
        closeText.fontColor = .white
        closeText.horizontalAlignmentMode = .center
        closeText.verticalAlignmentMode = .center
        closeBtn.addChild(closeText)
        topBar.addChild(closeBtn)
        
        scene.addChild(topBar)
        
        // 2. Bottom Controls HUD Container
        let bottomBar = SKShapeNode(rectOf: CGSize(width: VRMonitorNode.canvasWidth, height: 80), cornerRadius: 0)
        bottomBar.position = CGPoint(x: VRMonitorNode.canvasWidth / 2.0, y: 40)
        bottomBar.fillColor = UIColor(white: 0.05, alpha: 0.85)
        bottomBar.strokeColor = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.3)
        bottomBar.lineWidth = 1
        bottomBar.name = "hud_bottom_bar"
        bottomBar.yScale = -1.0
        
        // Progress Track Background
        let trackBg = SKShapeNode(rectOf: CGSize(width: VRMonitorNode.canvasWidth - 360, height: 8), cornerRadius: 4)
        trackBg.fillColor = UIColor(white: 1.0, alpha: 0.2)
        trackBg.strokeColor = .clear
        trackBg.position = CGPoint(x: 0, y: 22)
        trackBg.name = "hud_track_bg"
        bottomBar.addChild(trackBg)
        
        // Progress Fill
        let progressFill = SKShapeNode(rectOf: CGSize(width: 10, height: 8), cornerRadius: 4)
        progressFill.fillColor = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 1.0)
        progressFill.strokeColor = .clear
        progressFill.position = CGPoint(x: -((VRMonitorNode.canvasWidth - 360) / 2.0) + 5, y: 22)
        progressFill.name = "hud_progress_fill"
        bottomBar.addChild(progressFill)
        
        // Time Label
        let timeLabel = SKLabelNode(text: "00:00 / 00:00")
        timeLabel.fontSize = 14
        timeLabel.fontName = "HelveticaNeue-Bold"
        timeLabel.fontColor = UIColor(white: 1.0, alpha: 0.8)
        timeLabel.horizontalAlignmentMode = .left
        timeLabel.verticalAlignmentMode = .center
        timeLabel.position = CGPoint(x: -((VRMonitorNode.canvasWidth - 360) / 2.0), y: -16)
        timeLabel.name = "hud_time_label"
        bottomBar.addChild(timeLabel)
        
        // Play/Pause & Transport Labels
        let transportLabel = SKLabelNode(text: "⏪ -10s     ▶ / ⏸ Play / Pause     ⏩ +10s     🔄 Replay")
        transportLabel.fontSize = 16
        transportLabel.fontName = "HelveticaNeue-Bold"
        transportLabel.fontColor = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.95)
        transportLabel.horizontalAlignmentMode = .center
        transportLabel.verticalAlignmentMode = .center
        transportLabel.position = CGPoint(x: 40, y: -16)
        transportLabel.name = "hud_transport_label"
        bottomBar.addChild(transportLabel)
        
        // Audio Mute Label
        let muteLabel = SKLabelNode(text: "🔊 Audio")
        muteLabel.fontSize = 15
        muteLabel.fontName = "HelveticaNeue-Bold"
        muteLabel.fontColor = .white
        muteLabel.horizontalAlignmentMode = .right
        muteLabel.verticalAlignmentMode = .center
        muteLabel.position = CGPoint(x: ((VRMonitorNode.canvasWidth - 360) / 2.0), y: -16)
        muteLabel.name = "hud_mute_label"
        bottomBar.addChild(muteLabel)
        
        scene.addChild(bottomBar)
    }
    
    private func updateCinemaHUDOverlay() {
        guard let scene = videoSKScene,
              let bottomBar = scene.childNode(withName: "hud_bottom_bar") as? SKShapeNode else { return }
        
        let total = totalDurationSeconds > 0 ? totalDurationSeconds : 1.0
        let current = currentPlaybackSeconds
        let fraction = CGFloat(max(0.0, min(1.0, current / total)))
        
        let trackWidth = VRMonitorNode.canvasWidth - 360
        let fillWidth = max(8, trackWidth * fraction)
        
        if let progressFill = bottomBar.childNode(withName: "hud_progress_fill") as? SKShapeNode {
            let path = CGPath(roundedRect: CGRect(x: -(trackWidth / 2.0), y: 18, width: fillWidth, height: 8), cornerWidth: 4, cornerHeight: 4, transform: nil)
            progressFill.path = path
            progressFill.position = .zero
        }
        
        if let timeLabel = bottomBar.childNode(withName: "hud_time_label") as? SKLabelNode {
            let curMin = Int(current) / 60
            let curSec = Int(current) % 60
            let totMin = Int(total) / 60
            let totSec = Int(total) % 60
            timeLabel.text = String(format: "%02d:%02d / %02d:%02d", curMin, curSec, totMin, totSec)
        }
        
        if let muteLabel = bottomBar.childNode(withName: "hud_mute_label") as? SKLabelNode {
            muteLabel.text = isMuted ? "🔇 Muted" : "🔊 Audio"
            muteLabel.fontColor = isMuted ? .systemRed : .white
        }
    }
    
    // MARK: - Native CoreGraphics Canvas Renderer
    public func renderCurrentState() {
        guard !isCinemaMode else { return }
        
        let size = CGSize(width: VRMonitorNode.canvasWidth, height: VRMonitorNode.canvasHeight)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        var zones: [ClickableZone] = []
        
        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext
            
            // 1. Draw Deep Space Gradient Canvas
            drawBackgroundGradient(in: CGRect(origin: .zero, size: size), ctx: cgCtx)
            
            // 2. Draw Left Sidebar Dock
            let dockZones = drawSidebarDock(in: size, ctx: cgCtx)
            zones.append(contentsOf: dockZones)
            
            // 3. Draw Main Top Header Bar
            let mainArea = CGRect(x: 100, y: 0, width: size.width - 100, height: size.height)
            drawTopBar(in: mainArea, ctx: cgCtx)
            
            // 4. Draw View Content based on State Machine
            let contentRect = CGRect(x: 120, y: 80, width: size.width - 140, height: size.height - 100)
            
            switch currentState {
            case .home:
                let contentZones = drawHomeView(in: contentRect, ctx: cgCtx)
                zones.append(contentsOf: contentZones)
            case .webBrowser(let url, let title):
                // If we already have a cached web snapshot, draw it as the
                // main content (this is what makes the page visible). Otherwise
                // show the loading placeholder until the first snapshot arrives.
                if let snapshot = self.cachedWebSnapshot {
                    let webRect = CGRect(x: 100, y: 60, width: size.width - 100, height: size.height - 60)
                    snapshot.draw(in: webRect)
                } else {
                    let webLoadingZones = drawWebBrowserLoadingView(in: contentRect, url: url, title: title, ctx: cgCtx)
                    zones.append(contentsOf: webLoadingZones)
                }
            case .youtubeFeed:
                let youtubeZones = drawYouTubeFeedView(in: contentRect, ctx: cgCtx)
                zones.append(contentsOf: youtubeZones)
            case .settings:
                let settingsZones = drawSettingsView(in: contentRect, ctx: cgCtx)
                zones.append(contentsOf: settingsZones)
            case .cinemaTheater(let item):
                let cinemaZones = drawCinemaViewOverlay(in: contentRect, item: item, ctx: cgCtx)
                zones.append(contentsOf: cinemaZones)
            }
        }
        
        self.activeClickableZones = zones
        self.geometry?.firstMaterial?.diffuse.contents = image
        self.onSnapshotImage?(image)
    }
    
    // MARK: - Canvas Drawing Helpers
    
    private func drawBackgroundGradient(in rect: CGRect, ctx: CGContext) {
        let colors = [
            UIColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 1.0).cgColor,
            UIColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1.0).cgColor
        ]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: rect.width, y: rect.height), options: [])
        }
    }
    
    private func drawSidebarDock(in size: CGSize, ctx: CGContext) -> [ClickableZone] {
        var zones: [ClickableZone] = []
        let dockWidth: CGFloat = 100
        let dockRect = CGRect(x: 0, y: 0, width: dockWidth, height: size.height)
        
        // Dock background
        UIColor(red: 0.08, green: 0.11, blue: 0.20, alpha: 0.85).setFill()
        UIBezierPath(rect: dockRect).fill()
        
        // Dock right divider line
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.25).setStroke()
        let line = UIBezierPath()
        line.move(to: CGPoint(x: dockWidth, y: 0))
        line.addLine(to: CGPoint(x: dockWidth, y: size.height))
        line.lineWidth = 2
        line.stroke()
        
        // Dock Items
        let items: [(icon: String, title: String, state: SpatialViewState, action: () -> Void)] = [
            ("🏠", "Home", .home, { [weak self] in self?.setViewState(.home) }),
            ("▶️", "YouTube", .webBrowser(url: "https://m.youtube.com", title: "YouTube"), { [weak self] in
                self?.openWebURL("https://m.youtube.com", title: "YouTube")
            }),
            ("🎬", "Cinema", .youtubeFeed, { [weak self] in
                self?.setViewState(.youtubeFeed)
            }),
            ("🔍", "Google", .webBrowser(url: "https://www.google.com", title: "Google Search"), { [weak self] in
                self?.openWebURL("https://www.google.com", title: "Google Search")
            }),
            ("⚙️", "Settings", .settings, { [weak self] in self?.setViewState(.settings) }),
            ("🎯", "Center", .home, { [weak self] in self?.onRecalibrateRequested?() })
        ]
        
        var yPos: CGFloat = 30
        for item in items {
            let itemRect = CGRect(x: 10, y: yPos, width: 80, height: 70)
            let isCurrent: Bool
            switch (currentState, item.state) {
            case (.home, .home), (.settings, .settings), (.youtubeFeed, .youtubeFeed):
                isCurrent = true
            case (.webBrowser, .webBrowser):
                isCurrent = true
            default:
                isCurrent = false
            }
            
            if isCurrent {
                UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.25).setFill()
                let bgPath = UIBezierPath(roundedRect: itemRect, cornerRadius: 16)
                bgPath.fill()
                UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.8).setStroke()
                bgPath.lineWidth = 1.5
                bgPath.stroke()
            }
            
            // Draw Icon
            let iconFont = UIFont.systemFont(ofSize: 26)
            let iconAttr: [NSAttributedString.Key: Any] = [.font: iconFont, .foregroundColor: UIColor.white]
            let iconSize = (item.icon as NSString).size(withAttributes: iconAttr)
            (item.icon as NSString).draw(at: CGPoint(x: itemRect.midX - iconSize.width / 2, y: itemRect.minY + 8), withAttributes: iconAttr)
            
            // Draw Label
            let labelFont = UIFont.systemFont(ofSize: 12, weight: .bold)
            let labelAttr: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: isCurrent ? UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 1.0) : UIColor.white.withAlphaComponent(0.8)]
            let labelSize = (item.title as NSString).size(withAttributes: labelAttr)
            (item.title as NSString).draw(at: CGPoint(x: itemRect.midX - labelSize.width / 2, y: itemRect.minY + 44), withAttributes: labelAttr)
            
            zones.append(ClickableZone(rect: itemRect, action: item.action))
            yPos += 82
        }
        
        return zones
    }
    
    private func drawTopBar(in rect: CGRect, ctx: CGContext) -> [ClickableZone] {
        var zones: [ClickableZone] = []
        let topBarRect = CGRect(x: rect.minX, y: 0, width: rect.width, height: 60)
        UIColor(white: 1.0, alpha: 0.04).setFill()
        UIBezierPath(rect: topBarRect).fill()
        
        // Check if in Web Browser mode
        if case .webBrowser(let url, let title) = currentState {
            // Browser Navigation Toolbar
            let btnW: CGFloat = 36
            let backRect = CGRect(x: rect.minX + 16, y: 12, width: btnW, height: 36)
            UIColor(white: 1.0, alpha: 0.12).setFill()
            UIBezierPath(roundedRect: backRect, cornerRadius: 8).fill()
            ("◀" as NSString).draw(at: CGPoint(x: backRect.minX + 11, y: backRect.minY + 9), withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: UIColor.white])
            zones.append(ClickableZone(rect: backRect, action: { [weak self] in self?.goBack() }))
            
            let fwdRect = CGRect(x: backRect.maxX + 8, y: 12, width: btnW, height: 36)
            UIBezierPath(roundedRect: fwdRect, cornerRadius: 8).fill()
            ("▶" as NSString).draw(at: CGPoint(x: fwdRect.minX + 11, y: fwdRect.minY + 9), withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: UIColor.white])
            zones.append(ClickableZone(rect: fwdRect, action: { [weak self] in self?.goForward() }))
            
            let reloadRect = CGRect(x: fwdRect.maxX + 8, y: 12, width: btnW, height: 36)
            UIBezierPath(roundedRect: reloadRect, cornerRadius: 8).fill()
            ("↻" as NSString).draw(at: CGPoint(x: reloadRect.minX + 10, y: reloadRect.minY + 7), withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: UIColor.white])
            zones.append(ClickableZone(rect: reloadRect, action: { [weak self] in self?.reload() }))
            
            let homeRect = CGRect(x: reloadRect.maxX + 8, y: 12, width: btnW, height: 36)
            UIBezierPath(roundedRect: homeRect, cornerRadius: 8).fill()
            ("🏠" as NSString).draw(at: CGPoint(x: homeRect.minX + 8, y: homeRect.minY + 7), withAttributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.white])
            zones.append(ClickableZone(rect: homeRect, action: { [weak self] in self?.goHome() }))
            
            // Quick YouTube Button in Browser Bar
            let ytBtnRect = CGRect(x: homeRect.maxX + 8, y: 12, width: 80, height: 36)
            UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 0.7).setFill()
            UIBezierPath(roundedRect: ytBtnRect, cornerRadius: 8).fill()
            ("▶ YouTube" as NSString).draw(at: CGPoint(x: ytBtnRect.minX + 8, y: ytBtnRect.minY + 9), withAttributes: [.font: UIFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: UIColor.white])
            zones.append(ClickableZone(rect: ytBtnRect, action: { [weak self] in
                self?.openWebURL("https://m.youtube.com", title: "YouTube")
            }))
            
            // URL pill
            let urlRect = CGRect(x: ytBtnRect.maxX + 12, y: 12, width: rect.width - 500, height: 36)
            UIColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 0.9).setFill()
            let uPath = UIBezierPath(roundedRect: urlRect, cornerRadius: 10)
            uPath.fill()
            UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.4).setStroke()
            uPath.lineWidth = 1
            uPath.stroke()
            
            let displayURL = "🔒 " + (currentWebURL.isEmpty ? url : currentWebURL)
            (displayURL as NSString).draw(at: CGPoint(x: urlRect.minX + 14, y: urlRect.minY + 9), withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: UIColor.white])
            zones.append(ClickableZone(rect: urlRect, action: { [weak self] in
                self?.openWebURL("https://m.youtube.com", title: "YouTube")
            }))
            
            // Close Browser Button
            let closeBtnRect = CGRect(x: rect.maxX - 110, y: 12, width: 95, height: 36)
            UIColor(red: 0.85, green: 0.15, blue: 0.20, alpha: 0.85).setFill()
            let cPath = UIBezierPath(roundedRect: closeBtnRect, cornerRadius: 8)
            cPath.fill()
            ("✕ Close" as NSString).draw(at: CGPoint(x: closeBtnRect.minX + 18, y: closeBtnRect.minY + 9), withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: UIColor.white])
            zones.append(ClickableZone(rect: closeBtnRect, action: { [weak self] in self?.goHome() }))
            
            return zones
        }
        
        // Title
        let titleFont = UIFont.systemFont(ofSize: 20, weight: .heavy)
        let titleAttr: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.white]
        let titleText: String
        switch currentState {
        case .home: titleText = "MadhurVision OS • Spatial Hub"
        case .webBrowser(_, let title): titleText = "🌐 \(title)"
        case .cinemaTheater(let item): titleText = "🎬 Cinema Theater • \(item.category)"
        case .youtubeFeed: titleText = "📺 YouTube Spatial Feed"
        case .settings: titleText = "⚙️ System Settings"
        }
        (titleText as NSString).draw(at: CGPoint(x: rect.minX + 20, y: 18), withAttributes: titleAttr)
        
        // 120 FPS Metal Badge
        let badgeRect = CGRect(x: rect.maxX - 380, y: 14, width: 140, height: 32)
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.15).setFill()
        let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 8)
        badgePath.fill()
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.5).setStroke()
        badgePath.lineWidth = 1
        badgePath.stroke()
        
        let badgeFont = UIFont.systemFont(ofSize: 13, weight: .bold)
        let badgeAttr: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 1.0)]
        let badgeText = "⚡ 120 FPS Metal"
        let bSize = (badgeText as NSString).size(withAttributes: badgeAttr)
        (badgeText as NSString).draw(at: CGPoint(x: badgeRect.midX - bSize.width / 2, y: badgeRect.midY - bSize.height / 2), withAttributes: badgeAttr)
        
        // Clock
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let timeStr = timeFormatter.string(from: Date())
        let clockFont = UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        let clockAttr: [NSAttributedString.Key: Any] = [.font: clockFont, .foregroundColor: UIColor.white.withAlphaComponent(0.9)]
        (timeStr as NSString).draw(at: CGPoint(x: rect.maxX - 80, y: 18), withAttributes: clockAttr)
        
        return zones
    }
    
    private func drawWebBrowserLoadingView(in rect: CGRect, url: String, title: String, ctx: CGContext) -> [ClickableZone] {
        var zones: [ClickableZone] = []
        
        let containerRect = CGRect(x: rect.minX + 40, y: rect.minY + 40, width: rect.width - 80, height: rect.height - 80)
        let cPath = UIBezierPath(roundedRect: containerRect, cornerRadius: 20)
        UIColor(red: 0.06, green: 0.09, blue: 0.18, alpha: 0.9).setFill()
        cPath.fill()
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.3).setStroke()
        cPath.lineWidth = 1.5
        cPath.stroke()
        
        let icon = "🌐"
        let iAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 56), .foregroundColor: UIColor.white]
        (icon as NSString).draw(at: CGPoint(x: containerRect.midX - 28, y: containerRect.midY - 80), withAttributes: iAttr)
        
        let lTitle = "Loading \(title)..."
        let tAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: UIColor.white]
        let tSize = (lTitle as NSString).size(withAttributes: tAttr)
        (lTitle as NSString).draw(at: CGPoint(x: containerRect.midX - tSize.width / 2, y: containerRect.midY), withAttributes: tAttr)
        
        let uAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.8)]
        let uSize = (url as NSString).size(withAttributes: uAttr)
        (url as NSString).draw(at: CGPoint(x: containerRect.midX - uSize.width / 2, y: containerRect.midY + 36), withAttributes: uAttr)
        
        return zones
    }
    
    private func renderWebBrowserComposite(webImage: UIImage) {
        guard !isCinemaMode else { return }
        
        let size = CGSize(width: VRMonitorNode.canvasWidth, height: VRMonitorNode.canvasHeight)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        var zones: [ClickableZone] = []
        
        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext
            
            // 1. Draw Deep Space Background
            drawBackgroundGradient(in: CGRect(origin: .zero, size: size), ctx: cgCtx)
            
            // 2. Draw Left Sidebar Dock
            let dockZones = drawSidebarDock(in: size, ctx: cgCtx)
            zones.append(contentsOf: dockZones)
            
            // 3. Draw Top Browser Header Bar
            let mainArea = CGRect(x: 100, y: 0, width: size.width - 100, height: 60)
            let topZones = drawTopBar(in: mainArea, ctx: cgCtx)
            zones.append(contentsOf: topZones)
            
            // 4. Draw Web Page Content Area
            let webRect = CGRect(x: 100, y: 60, width: size.width - 100, height: size.height - 60)
            webImage.draw(in: webRect)
        }
        
        self.activeClickableZones = zones
        self.geometry?.firstMaterial?.diffuse.contents = image
        self.onSnapshotImage?(image)
    }
    
    private func drawHomeView(in rect: CGRect, ctx: CGContext) -> [ClickableZone] {
        var zones: [ClickableZone] = []
        
        // 1. OMNIBAR SEARCH & NAVIGATION
        let omniRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 48)
        let omniPath = UIBezierPath(roundedRect: omniRect, cornerRadius: 14)
        UIColor(red: 0.08, green: 0.12, blue: 0.22, alpha: 0.8).setFill()
        omniPath.fill()
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.35).setStroke()
        omniPath.lineWidth = 1.5
        omniPath.stroke()
        
        // Nav buttons (Back, Forward, Reload)
        let btnW: CGFloat = 36
        let backRect = CGRect(x: omniRect.minX + 8, y: omniRect.minY + 6, width: btnW, height: 36)
        UIColor(white: 1.0, alpha: 0.1).setFill()
        UIBezierPath(roundedRect: backRect, cornerRadius: 8).fill()
        ("◀" as NSString).draw(at: CGPoint(x: backRect.minX + 11, y: backRect.minY + 9), withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: UIColor.white])
        zones.append(ClickableZone(rect: backRect, action: { [weak self] in self?.goBack() }))
        
        let fwdRect = CGRect(x: backRect.maxX + 6, y: omniRect.minY + 6, width: btnW, height: 36)
        UIBezierPath(roundedRect: fwdRect, cornerRadius: 8).fill()
        ("▶" as NSString).draw(at: CGPoint(x: fwdRect.minX + 11, y: fwdRect.minY + 9), withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: UIColor.white])
        zones.append(ClickableZone(rect: fwdRect, action: { [weak self] in self?.goForward() }))
        
        let reloadRect = CGRect(x: fwdRect.maxX + 6, y: omniRect.minY + 6, width: btnW, height: 36)
        UIBezierPath(roundedRect: reloadRect, cornerRadius: 8).fill()
        ("↻" as NSString).draw(at: CGPoint(x: reloadRect.minX + 10, y: reloadRect.minY + 7), withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: UIColor.white])
        zones.append(ClickableZone(rect: reloadRect, action: { [weak self] in self?.reload() }))
        
        // Search Input placeholder
        let inputRect = CGRect(x: reloadRect.maxX + 12, y: omniRect.minY + 6, width: omniRect.width - 240, height: 36)
        UIColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 0.9).setFill()
        let inPath = UIBezierPath(roundedRect: inputRect, cornerRadius: 8)
        inPath.fill()
        UIColor(white: 1.0, alpha: 0.15).setStroke()
        inPath.lineWidth = 1
        inPath.stroke()
        
        let placeholder = "🔍 Search Google, YouTube, or enter URL (e.g. google.com, youtube.com)..."
        (placeholder as NSString).draw(at: CGPoint(x: inputRect.minX + 14, y: inputRect.minY + 9), withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.white.withAlphaComponent(0.6)])
        zones.append(ClickableZone(rect: inputRect, action: { [weak self] in
            self?.openWebURL("https://www.google.com", title: "Google Search")
        }))
        
        // Open button
        let openBtnRect = CGRect(x: omniRect.maxX - 100, y: omniRect.minY + 6, width: 92, height: 36)
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.9).setFill()
        let obPath = UIBezierPath(roundedRect: openBtnRect, cornerRadius: 8)
        obPath.fill()
        let oText = "Open ↵"
        (oText as NSString).draw(at: CGPoint(x: openBtnRect.minX + 18, y: openBtnRect.minY + 9), withAttributes: [.font: UIFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: UIColor.black])
        zones.append(ClickableZone(rect: openBtnRect, action: { [weak self] in
            self?.openWebURL("https://www.google.com", title: "Google Search")
        }))
        
        // 2. HERO BANNER
        let heroY = omniRect.maxY + 14
        let heroRect = CGRect(x: rect.minX, y: heroY, width: rect.width, height: 60)
        let heroTitle = "MadhurVision"
        (heroTitle as NSString).draw(at: CGPoint(x: heroRect.minX + 8, y: heroRect.minY + 4), withAttributes: [.font: UIFont.systemFont(ofSize: 26, weight: .black), .foregroundColor: UIColor.white])
        
        let heroSub = "Your Spatial VR Computing System • Select an application to launch"
        (heroSub as NSString).draw(at: CGPoint(x: heroRect.minX + 8, y: heroRect.minY + 36), withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.85)])
        
        // 3. FULL DESKTOP APP GRID (3 rows x 3 columns = 9 Apps)
        struct AppCardData {
            let icon: String
            let title: String
            let desc: String
            let gradient: [UIColor]
            let action: () -> Void
        }
        
        let appCards: [AppCardData] = [
            AppCardData(
                icon: "▶️",
                title: "YouTube Web",
                desc: "Search, browse channels, creators & live streams in VR",
                gradient: [UIColor(red: 0.45, green: 0.06, blue: 0.06, alpha: 0.85), UIColor(red: 0.18, green: 0.02, blue: 0.02, alpha: 0.85)],
                action: { [weak self] in
                    self?.openWebURL("https://m.youtube.com", title: "YouTube")
                }
            ),
            AppCardData(
                icon: "🎬",
                title: "Spatial Cinema 4K",
                desc: "Direct Metal GPU Video Streaming with zero lag & 60 FPS",
                gradient: [UIColor(red: 0.35, green: 0.10, blue: 0.30, alpha: 0.8), UIColor(red: 0.12, green: 0.03, blue: 0.14, alpha: 0.8)],
                action: { [weak self] in
                    self?.setViewState(.youtubeFeed)
                }
            ),
            AppCardData(
                icon: "🔍",
                title: "Google Search",
                desc: "Browse the web with desktop-class performance",
                gradient: [UIColor(red: 0.10, green: 0.18, blue: 0.35, alpha: 0.8), UIColor(red: 0.04, green: 0.08, blue: 0.18, alpha: 0.8)],
                action: { [weak self] in
                    self?.openWebURL("https://www.google.com", title: "Google Search")
                }
            ),
            AppCardData(
                icon: "🖥️",
                title: "PC Remote Desktop",
                desc: "Mirror your Windows laptop screen in VR at 60 FPS",
                gradient: [UIColor(red: 0.08, green: 0.28, blue: 0.38, alpha: 0.8), UIColor(red: 0.02, green: 0.10, blue: 0.16, alpha: 0.8)],
                action: { [weak self] in
                    self?.openWebURL("http://192.168.31.115:8082", title: "PC Remote Monitor")
                }
            ),
            AppCardData(
                icon: "🎧",
                title: "Lo-Fi Beats VR",
                desc: "Relaxing chill beats to study and focus in 3D",
                gradient: [UIColor(red: 0.25, green: 0.10, blue: 0.40, alpha: 0.8), UIColor(red: 0.08, green: 0.03, blue: 0.18, alpha: 0.8)],
                action: { [weak self] in
                    guard let self = self else { return }
                    self.startCinemaStream(item: self.cinemaCatalog[2])
                }
            ),
            AppCardData(
                icon: "📚",
                title: "Wikipedia Spatial",
                desc: "Explore spatial knowledge, science, and history",
                gradient: [UIColor(red: 0.12, green: 0.22, blue: 0.28, alpha: 0.8), UIColor(red: 0.04, green: 0.08, blue: 0.12, alpha: 0.8)],
                action: { [weak self] in
                    self?.openWebURL("https://www.wikipedia.org", title: "Wikipedia Spatial")
                }
            ),
            AppCardData(
                icon: "💬",
                title: "Reddit VR",
                desc: "Community discussions, news, tech, and gaming",
                gradient: [UIColor(red: 0.35, green: 0.15, blue: 0.05, alpha: 0.8), UIColor(red: 0.14, green: 0.05, blue: 0.02, alpha: 0.8)],
                action: { [weak self] in
                    self?.openWebURL("https://www.reddit.com", title: "Reddit VR")
                }
            ),
            AppCardData(
                icon: "⚡",
                title: "Speed Test",
                desc: "Check your network streaming bandwidth & latency",
                gradient: [UIColor(red: 0.20, green: 0.25, blue: 0.05, alpha: 0.8), UIColor(red: 0.08, green: 0.10, blue: 0.02, alpha: 0.8)],
                action: { [weak self] in
                    self?.openWebURL("https://fast.com", title: "Fast.com Speed Test")
                }
            ),
            AppCardData(
                icon: "⚙️",
                title: "System Settings",
                desc: "Adjust display scale, stereo lens optical inset, & IPD",
                gradient: [UIColor(red: 0.15, green: 0.18, blue: 0.25, alpha: 0.8), UIColor(red: 0.06, green: 0.07, blue: 0.12, alpha: 0.8)],
                action: { [weak self] in
                    self?.setViewState(.settings)
                }
            )
        ]
        
        let gridY = heroRect.maxY + 10
        let cardWidth: CGFloat = (rect.width - 40) / 3.0
        let cardHeight: CGFloat = 160
        let spacing: CGFloat = 16
        
        for (index, card) in appCards.enumerated() {
            let row = CGFloat(index / 3)
            let col = CGFloat(index % 3)
            let cardRect = CGRect(
                x: rect.minX + col * (cardWidth + spacing),
                y: gridY + row * (cardHeight + spacing),
                width: cardWidth,
                height: cardHeight
            )
            
            // Card Background Gradient
            let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 16)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let cColors = card.gradient.map { $0.cgColor }
            if let cGrad = CGGradient(colorsSpace: colorSpace, colors: cColors as CFArray, locations: [0.0, 1.0]) {
                ctx.saveGState()
                cardPath.addClip()
                ctx.drawLinearGradient(cGrad, start: CGPoint(x: cardRect.minX, y: cardRect.minY), end: CGPoint(x: cardRect.maxX, y: cardRect.maxY), options: [])
                ctx.restoreGState()
            }
            
            // Card border
            UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.25).setStroke()
            cardPath.lineWidth = 1.2
            cardPath.stroke()
            
            // Icon
            let iconFont = UIFont.systemFont(ofSize: 34)
            let iAttr: [NSAttributedString.Key: Any] = [.font: iconFont, .foregroundColor: UIColor.white]
            (card.icon as NSString).draw(at: CGPoint(x: cardRect.minX + 16, y: cardRect.minY + 16), withAttributes: iAttr)
            
            // Title
            let tFont = UIFont.systemFont(ofSize: 17, weight: .bold)
            let tAttr: [NSAttributedString.Key: Any] = [.font: tFont, .foregroundColor: UIColor.white]
            (card.title as NSString).draw(at: CGPoint(x: cardRect.minX + 64, y: cardRect.minY + 22), withAttributes: tAttr)
            
            // Description
            let dFont = UIFont.systemFont(ofSize: 12)
            let dAttr: [NSAttributedString.Key: Any] = [.font: dFont, .foregroundColor: UIColor.white.withAlphaComponent(0.75)]
            let dRect = CGRect(x: cardRect.minX + 16, y: cardRect.minY + 68, width: cardRect.width - 32, height: 45)
            (card.desc as NSString).draw(in: dRect, withAttributes: dAttr)
            
            // Launch Chip Badge
            let launchRect = CGRect(x: cardRect.maxX - 80, y: cardRect.maxY - 34, width: 68, height: 22)
            UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.2).setFill()
            UIBezierPath(roundedRect: launchRect, cornerRadius: 6).fill()
            let lAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 1.0)]
            ("Launch ↵" as NSString).draw(at: CGPoint(x: launchRect.minX + 8, y: launchRect.minY + 4), withAttributes: lAttr)
            
            zones.append(ClickableZone(rect: cardRect, action: card.action))
        }
        
        return zones
    }
    
    private func drawYouTubeFeedView(in rect: CGRect, ctx: CGContext) -> [ClickableZone] {
        var zones: [ClickableZone] = []
        
        // 1. Header Banner
        let heroRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 72)
        let heroPath = UIBezierPath(roundedRect: heroRect, cornerRadius: 16)
        UIColor(red: 0.08, green: 0.12, blue: 0.25, alpha: 0.7).setFill()
        heroPath.fill()
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.35).setStroke()
        heroPath.lineWidth = 1.2
        heroPath.stroke()
        
        let heroTitle = "🎬 Direct Metal Spatial Cinema & YouTube Theater"
        (heroTitle as NSString).draw(at: CGPoint(x: heroRect.minX + 20, y: heroRect.minY + 12), withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: UIColor.white])
        
        let heroSub = "Direct GPU zero-copy hardware video decoding • Full 3D Hand Tracking & Laser Control"
        (heroSub as NSString).draw(at: CGPoint(x: heroRect.minX + 20, y: heroRect.minY + 42), withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.9)])
        
        // 2. Category Filter Bar
        let categories = ["All", "Nature 4K", "Sci-Fi IMAX", "Music & Lo-Fi", "Animation & Movies", "Apple & VR Tech", "Gaming"]
        let pillY = heroRect.maxY + 12
        var pillX = rect.minX
        let pillHeight: CGFloat = 34
        
        for cat in categories {
            let isSel = (self.selectedCategory == cat)
            let font = UIFont.systemFont(ofSize: 13, weight: isSel ? .bold : .medium)
            let textWidth = (cat as NSString).size(withAttributes: [.font: font]).width
            let pillWidth = textWidth + 24
            let pillRect = CGRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
            
            let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: 17)
            if isSel {
                UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.95).setFill()
                pillPath.fill()
            } else {
                UIColor(white: 1.0, alpha: 0.08).setFill()
                pillPath.fill()
                UIColor(white: 1.0, alpha: 0.2).setStroke()
                pillPath.lineWidth = 1.0
                pillPath.stroke()
            }
            
            let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: isSel ? UIColor.black : UIColor.white]
            (cat as NSString).draw(at: CGPoint(x: pillRect.midX - textWidth / 2.0, y: pillRect.midY - 8), withAttributes: attr)
            
            zones.append(ClickableZone(rect: pillRect, action: { [weak self] in
                guard let self = self else { return }
                self.selectedCategory = cat
                self.renderCurrentState()
            }))
            pillX += pillWidth + 10
        }
        
        // 3. Filtered Catalog Grid
        let filteredCatalog = (selectedCategory == "All") ? cinemaCatalog : cinemaCatalog.filter { $0.category.contains(selectedCategory) }
        let gridY = pillY + pillHeight + 14
        let cardWidth: CGFloat = (rect.width - 40) / 3.0
        let cardHeight: CGFloat = 265
        let spacing: CGFloat = 20
        
        for (index, item) in filteredCatalog.prefix(6).enumerated() {
            let row = CGFloat(index / 3)
            let col = CGFloat(index % 3)
            let cardRect = CGRect(
                x: rect.minX + col * (cardWidth + spacing),
                y: gridY + row * (cardHeight + spacing),
                width: cardWidth,
                height: cardHeight
            )
            let cardZone = drawVideoCard(item: item, in: cardRect, ctx: ctx)
            zones.append(cardZone)
        }
        
        return zones
    }
    
    private func drawVideoCard(item: SpatialVideoItem, in cardRect: CGRect, ctx: CGContext) -> ClickableZone {
        // Card Background Gradient
        let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 16)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let cColors = item.gradientColors.map { $0.cgColor }
        if let cGrad = CGGradient(colorsSpace: colorSpace, colors: cColors as CFArray, locations: [0.0, 1.0]) {
            ctx.saveGState()
            cardPath.addClip()
            ctx.drawLinearGradient(cGrad, start: CGPoint(x: cardRect.minX, y: cardRect.minY), end: CGPoint(x: cardRect.maxX, y: cardRect.maxY), options: [])
            ctx.restoreGState()
        }
        
        // Glowing border
        UIColor(white: 1.0, alpha: 0.18).setStroke()
        cardPath.lineWidth = 1.2
        cardPath.stroke()
        
        // Thumbnail Area
        let thumbRect = CGRect(x: cardRect.minX + 10, y: cardRect.minY + 10, width: cardRect.width - 20, height: 135)
        let thumbPath = UIBezierPath(roundedRect: thumbRect, cornerRadius: 12)
        UIColor(white: 0.0, alpha: 0.45).setFill()
        thumbPath.fill()
        
        // Icon
        let iconFont = UIFont.systemFont(ofSize: 40)
        let iAttr: [NSAttributedString.Key: Any] = [.font: iconFont, .foregroundColor: UIColor.white]
        let iSize = (item.icon as NSString).size(withAttributes: iAttr)
        (item.icon as NSString).draw(at: CGPoint(x: thumbRect.midX - iSize.width / 2, y: thumbRect.midY - iSize.height / 2), withAttributes: iAttr)
        
        // Category Tag
        let tagRect = CGRect(x: thumbRect.minX + 8, y: thumbRect.maxY - 26, width: 95, height: 18)
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.35).setFill()
        UIBezierPath(roundedRect: tagRect, cornerRadius: 5).fill()
        (item.category as NSString).draw(at: CGPoint(x: tagRect.minX + 5, y: tagRect.minY + 2), withAttributes: [.font: UIFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: UIColor.white])
        
        // Duration Badge
        let durRect = CGRect(x: thumbRect.maxX - 55, y: thumbRect.maxY - 26, width: 47, height: 18)
        UIColor(white: 0.0, alpha: 0.75).setFill()
        UIBezierPath(roundedRect: durRect, cornerRadius: 5).fill()
        (item.duration as NSString).draw(at: CGPoint(x: durRect.minX + 6, y: durRect.minY + 2), withAttributes: [.font: UIFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: UIColor.white])
        
        // Video Title
        let titleBounding = CGRect(x: cardRect.minX + 12, y: thumbRect.maxY + 8, width: cardRect.width - 24, height: 38)
        (item.title as NSString).draw(in: titleBounding, withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: UIColor.white])
        
        // Channel
        (item.channel as NSString).draw(at: CGPoint(x: cardRect.minX + 12, y: cardRect.maxY - 34), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.white.withAlphaComponent(0.65)])
        
        // Play Button
        let playBtnRect = CGRect(x: cardRect.maxX - 80, y: cardRect.maxY - 40, width: 70, height: 26)
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.95).setFill()
        UIBezierPath(roundedRect: playBtnRect, cornerRadius: 13).fill()
        let pText = "▶ Play"
        let pAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: UIColor.black]
        let pSize = (pText as NSString).size(withAttributes: pAttr)
        (pText as NSString).draw(at: CGPoint(x: playBtnRect.midX - pSize.width / 2, y: playBtnRect.midY - pSize.height / 2), withAttributes: pAttr)
        
        return ClickableZone(rect: cardRect, action: { [weak self] in
            self?.startCinemaStream(item: item)
        })
    }
    
    private func drawSettingsView(in rect: CGRect, ctx: CGContext) -> [ClickableZone] {
        var zones: [ClickableZone] = []
        
        let containerRect = CGRect(x: rect.minX + 40, y: rect.minY + 20, width: rect.width - 80, height: rect.height - 40)
        let cPath = UIBezierPath(roundedRect: containerRect, cornerRadius: 20)
        UIColor(red: 0.08, green: 0.11, blue: 0.22, alpha: 0.7).setFill()
        cPath.fill()
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.25).setStroke()
        cPath.lineWidth = 1.5
        cPath.stroke()
        
        var y: CGFloat = containerRect.minY + 30
        
        // SECTION 1: Virtual Display Scale
        let sTitle = "Virtual Display Sizing"
        (sTitle as NSString).draw(at: CGPoint(x: containerRect.minX + 30, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: UIColor.white])
        y += 40
        
        let scales: [(title: String, val: CGFloat)] = [
            ("10\" Compact", 0.7),
            ("12\" Standard", 1.0),
            ("15\" Theater", 1.4),
            ("50\" IMAX Cinema", 2.0)
        ]
        
        let btnWidth: CGFloat = 160
        var btnX = containerRect.minX + 30
        for s in scales {
            let bRect = CGRect(x: btnX, y: y, width: btnWidth, height: 44)
            let isSel = abs(self.currentScale - s.val) < 0.1
            if isSel {
                UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.9).setFill()
            } else {
                UIColor(white: 1.0, alpha: 0.08).setFill()
            }
            let bPath = UIBezierPath(roundedRect: bRect, cornerRadius: 12)
            bPath.fill()
            
            let bAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: isSel ? UIColor.black : UIColor.white]
            let bSize = (s.title as NSString).size(withAttributes: bAttr)
            (s.title as NSString).draw(at: CGPoint(x: bRect.midX - bSize.width / 2, y: bRect.midY - bSize.height / 2), withAttributes: bAttr)
            
            zones.append(ClickableZone(rect: bRect, action: { [weak self] in
                guard let self = self else { return }
                self.currentScale = s.val
                self.onScaleChanged?(s.val)
                self.renderCurrentState()
            }))
            btnX += btnWidth + 15
        }
        y += 70
        
        // SECTION 2: Stereo Lens Alignment (IPD & Screen Inset)
        let lTitle = "Stereo Lens Alignment (Eye Separation & 3D Merging)"
        (lTitle as NSString).draw(at: CGPoint(x: containerRect.minX + 30, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: UIColor.white])
        y += 40
        
        let lensPresets: [(title: String, offset: CGFloat, ipd: Float)] = [
            ("58mm Narrow", 48.0, 0.058),
            ("63mm Std Max", 34.0, 0.063),
            ("68mm Wide", 18.0, 0.068),
            ("72mm Ultra", 4.0, 0.072)
        ]
        
        var lBtnX = containerRect.minX + 30
        for lp in lensPresets {
            let bRect = CGRect(x: lBtnX, y: y, width: btnWidth, height: 44)
            let isSel = abs(self.currentLensOffset - lp.offset) < 2.0
            if isSel {
                UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.9).setFill()
            } else {
                UIColor(white: 1.0, alpha: 0.08).setFill()
            }
            let bPath = UIBezierPath(roundedRect: bRect, cornerRadius: 12)
            bPath.fill()
            
            let bAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: isSel ? UIColor.black : UIColor.white]
            let bSize = (lp.title as NSString).size(withAttributes: bAttr)
            (lp.title as NSString).draw(at: CGPoint(x: bRect.midX - bSize.width / 2, y: bRect.midY - bSize.height / 2), withAttributes: bAttr)
            
            zones.append(ClickableZone(rect: bRect, action: { [weak self] in
                guard let self = self else { return }
                self.currentLensOffset = lp.offset
                self.currentIPD = lp.ipd
                self.onLensOffsetChanged?(lp.offset, lp.ipd)
                self.renderCurrentState()
            }))
            lBtnX += btnWidth + 15
        }
        y += 70
        
        // SECTION 3: Orientation & Head Recalibration
        let rTitle = "Orientation & Recalibration"
        (rTitle as NSString).draw(at: CGPoint(x: containerRect.minX + 30, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: UIColor.white])
        y += 40
        
        let recalBtnRect = CGRect(x: containerRect.minX + 30, y: y, width: 280, height: 48)
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.2).setFill()
        let rPath = UIBezierPath(roundedRect: recalBtnRect, cornerRadius: 14)
        rPath.fill()
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.8).setStroke()
        rPath.lineWidth = 1.5
        rPath.stroke()
        
        let rText = "🎯 Recalibrate Center View"
        let rAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: UIColor.white]
        let rSize = (rText as NSString).size(withAttributes: rAttr)
        (rText as NSString).draw(at: CGPoint(x: recalBtnRect.midX - rSize.width / 2, y: recalBtnRect.midY - rSize.height / 2), withAttributes: rAttr)
        
        zones.append(ClickableZone(rect: recalBtnRect, action: { [weak self] in
            self?.onRecalibrateRequested?()
        }))
        
        // Exit VR Button
        let exitBtnRect = CGRect(x: recalBtnRect.maxX + 20, y: y, width: 180, height: 48)
        UIColor(red: 1.0, green: 0.2, blue: 0.3, alpha: 0.2).setFill()
        let ePath = UIBezierPath(roundedRect: exitBtnRect, cornerRadius: 14)
        ePath.fill()
        UIColor(red: 1.0, green: 0.3, blue: 0.4, alpha: 0.8).setStroke()
        ePath.lineWidth = 1.5
        ePath.stroke()
        
        let eText = "✕ Exit VR"
        let eAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: UIColor(red: 1.0, green: 0.5, blue: 0.6, alpha: 1.0)]
        let eSize = (eText as NSString).size(withAttributes: eAttr)
        (eText as NSString).draw(at: CGPoint(x: exitBtnRect.midX - eSize.width / 2, y: exitBtnRect.midY - eSize.height / 2), withAttributes: eAttr)
        
        zones.append(ClickableZone(rect: exitBtnRect, action: { [weak self] in
            self?.onExitVRRequested?()
        }))
        
        return zones
    }
    
    private func drawCinemaViewOverlay(in rect: CGRect, item: SpatialVideoItem, ctx: CGContext) -> [ClickableZone] {
        var zones: [ClickableZone] = []
        registerCinemaClickZones(item: item)
        return zones
    }
    
    private func registerCinemaClickZones(item: SpatialVideoItem) {
        var zones: [ClickableZone] = []
        
        // 1. Left dock items (Home & Exit Cinema)
        let dockZone = ClickableZone(rect: CGRect(x: 0, y: 0, width: 100, height: VRMonitorNode.canvasHeight), action: { [weak self] in
            self?.exitCinemaMode()
        })
        zones.append(dockZone)
        
        // 2. Top HUD Overlay: Close Theater Button (top right)
        let closeRect = CGRect(x: VRMonitorNode.canvasWidth - 200, y: 0, width: 200, height: 75)
        let closeZone = ClickableZone(rect: closeRect, action: { [weak self] in
            self?.exitCinemaMode()
        })
        zones.append(closeZone)
        
        // 3. Bottom Transport Controls (Rewind -10s, Play/Pause, Fast-Forward +10s, Replay, Mute)
        let bottomY = VRMonitorNode.canvasHeight - 65
        
        // -10s Seek Backward
        let rewindRect = CGRect(x: VRMonitorNode.canvasWidth / 2.0 - 240, y: bottomY, width: 90, height: 60)
        zones.append(ClickableZone(rect: rewindRect, action: { [weak self] in
            self?.seekCinema(by: -10)
        }))
        
        // Play / Pause
        let playPauseRect = CGRect(x: VRMonitorNode.canvasWidth / 2.0 - 140, y: bottomY, width: 160, height: 60)
        zones.append(ClickableZone(rect: playPauseRect, action: { [weak self] in
            self?.togglePlayPauseCinema()
        }))
        
        // +10s Seek Forward
        let fwdRect = CGRect(x: VRMonitorNode.canvasWidth / 2.0 + 30, y: bottomY, width: 90, height: 60)
        zones.append(ClickableZone(rect: fwdRect, action: { [weak self] in
            self?.seekCinema(by: 10)
        }))
        
        // Replay
        let replayRect = CGRect(x: VRMonitorNode.canvasWidth / 2.0 + 130, y: bottomY, width: 90, height: 60)
        zones.append(ClickableZone(rect: replayRect, action: { [weak self] in
            self?.seekCinemaTo(seconds: 0)
        }))
        
        // Mute / Unmute
        let muteRect = CGRect(x: VRMonitorNode.canvasWidth - 240, y: bottomY, width: 120, height: 60)
        zones.append(ClickableZone(rect: muteRect, action: { [weak self] in
            self?.toggleMuteCinema()
        }))
        
        // 4. Center Screen Tap (Toggle Play/Pause)
        let screenCenterRect = CGRect(x: 120, y: 80, width: VRMonitorNode.canvasWidth - 240, height: VRMonitorNode.canvasHeight - 170)
        let centerZone = ClickableZone(rect: screenCenterRect, action: { [weak self] in
            self?.togglePlayPauseCinema()
        })
        zones.append(centerZone)
        
        self.activeClickableZones = zones
    }
    
    // MARK: - Glowing Border Frame
    private func addBorderFrame(width: CGFloat, height: CGFloat) {
        let borderPlane = SCNPlane(width: width + 0.08, height: height + 0.08)
        borderPlane.cornerRadius = 0.06
        
        let borderMaterial = SCNMaterial()
        borderMaterial.diffuse.contents = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.15)
        borderMaterial.emission.contents = UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.8)
        borderMaterial.lightingModel = .constant
        borderMaterial.isDoubleSided = true
        borderPlane.materials = [borderMaterial]
        
        let borderNode = SCNNode(geometry: borderPlane)
        borderNode.name = "monitor_border"
        borderNode.position = SCNVector3(0, 0, -0.003)
        addChildNode(borderNode)
    }
}
