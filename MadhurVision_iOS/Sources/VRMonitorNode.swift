import SceneKit
import UIKit
import AVFoundation
import SpriteKit

/// Native Spatial Video Item Model
public struct SpatialVideoItem: Identifiable {
    public let id: String
    public let title: String
    public let channel: String
    public let category: String
    public let streamURL: String
    public let icon: String
    public let gradientColors: [UIColor]
}

/// Pure Native Spatial OS for VR Monitor (Zero WebKit)
public final class VRMonitorNode: SCNNode {
    
    // MARK: - Canvas Dimensions
    public static let canvasWidth: CGFloat = 1440
    public static let canvasHeight: CGFloat = 810
    
    public let monitorWidth: CGFloat
    public let monitorHeight: CGFloat
    
    // MARK: - State Machine
    public enum SpatialViewState {
        case home
        case cinemaTheater(item: SpatialVideoItem)
        case youtubeFeed
        case settings
    }
    
    public private(set) var currentState: SpatialViewState = .home
    
    // MARK: - Cinema Player Engine (Direct Metal GPU Texture)
    private var cinemaPlayer: AVPlayer?
    private var videoSKNode: SKVideoNode?
    private var videoSKScene: SKScene?
    public private(set) var isCinemaMode: Bool = false
    public private(set) var currentVideoTitle: String = ""
    
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
    
    // MARK: - Curated 4K Cinema Video Catalog
    public let cinemaCatalog: [SpatialVideoItem] = [
        SpatialVideoItem(
            id: "nature_4k",
            title: "Earth 4K HDR • Breathtaking Wildlife & Landscapes",
            channel: "BBC Earth Showcase",
            category: "Nature 4K",
            streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
            icon: "🌿",
            gradientColors: [UIColor(red: 0.05, green: 0.35, blue: 0.20, alpha: 1.0), UIColor(red: 0.02, green: 0.15, blue: 0.08, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "interstellar_imax",
            title: "Interstellar Cosmic Flight • Deep Space 4K Experience",
            channel: "Hans Zimmer IMAX",
            category: "Sci-Fi IMAX",
            streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4",
            icon: "🚀",
            gradientColors: [UIColor(red: 0.10, green: 0.15, blue: 0.45, alpha: 1.0), UIColor(red: 0.03, green: 0.05, blue: 0.20, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "lofi_beats",
            title: "Lofi Girl • Relaxing Chill Beats to Study in VR",
            channel: "Lofi Girl Records",
            category: "Lo-Fi Music",
            streamURL: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
            icon: "🎧",
            gradientColors: [UIColor(red: 0.40, green: 0.10, blue: 0.35, alpha: 1.0), UIColor(red: 0.15, green: 0.03, blue: 0.15, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "spatial_vision",
            title: "Apple Vision Pro Spatial Computing Showcase",
            channel: "Tech Vision Spatial",
            category: "Spatial VR",
            streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
            icon: "🥽",
            gradientColors: [UIColor(red: 0.05, green: 0.30, blue: 0.45, alpha: 1.0), UIColor(red: 0.02, green: 0.10, blue: 0.20, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "blender_animation",
            title: "Elephants Dream • 4K Open Movie Animation",
            channel: "Blender Animation Studio",
            category: "Animation 4K",
            streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4",
            icon: "🎞️",
            gradientColors: [UIColor(red: 0.45, green: 0.20, blue: 0.05, alpha: 1.0), UIColor(red: 0.20, green: 0.08, blue: 0.02, alpha: 1.0)]
        ),
        SpatialVideoItem(
            id: "apple_hls",
            title: "Apple Adaptive Bitrate Spatial HLS Demo",
            channel: "Apple Developer Streaming",
            category: "Apple HLS",
            streamURL: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8",
            icon: "⚡",
            gradientColors: [UIColor(red: 0.25, green: 0.05, blue: 0.45, alpha: 1.0), UIColor(red: 0.10, green: 0.02, blue: 0.20, alpha: 1.0)]
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
        
        // Check clickable zones from top to bottom
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
        // Native scroll support for catalog/feeds if needed
    }
    
    // MARK: - State Navigation
    public func setViewState(_ state: SpatialViewState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isCinemaMode {
                self.exitCinemaMode()
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
        case .home:
            break
        default:
            goHome()
        }
    }
    
    public func goForward() {}
    public func reload() {
        renderCurrentState()
    }
    
    // MARK: - Direct Metal GPU Video Cinema Engine
    public func startCinemaStream(item: SpatialVideoItem) {
        guard let url = URL(string: item.streamURL) else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.cinemaPlayer?.pause()
            self.videoSKNode?.removeFromParent()
            self.videoSKNode = nil
            self.videoSKScene = nil
            
            let playerItem = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: playerItem)
            player.actionAtItemEnd = .none
            self.cinemaPlayer = player
            self.isCinemaMode = true
            self.currentVideoTitle = item.title
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
            self.videoSKScene = skScene
            self.videoSKNode = videoNode
            
            // Assign dynamic SpriteKit video texture to SCNMaterial
            self.geometry?.firstMaterial?.diffuse.contents = skScene
            videoNode.play()
            player.play()
            
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
            self.cinemaPlayer = nil
            self.videoSKNode?.removeFromParent()
            self.videoSKNode = nil
            self.videoSKScene = nil
            self.isCinemaMode = false
            self.currentState = .home
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
    }
    
    public func seekCinema(by seconds: Double) {
        guard let player = cinemaPlayer else { return }
        let current = player.currentTime()
        let target = CMTimeAdd(current, CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: target)
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
            case .home, .youtubeFeed:
                let contentZones = drawHomeView(in: contentRect, ctx: cgCtx)
                zones.append(contentsOf: contentZones)
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
            ("🎬", "Cinema", .cinemaTheater(item: self.cinemaCatalog[0]), { [weak self] in
                guard let self = self else { return }
                self.startCinemaStream(item: self.cinemaCatalog[0])
            }),
            ("⚙️", "Settings", .settings, { [weak self] in self?.setViewState(.settings) }),
            ("🎯", "Center", .home, { [weak self] in self?.onRecalibrateRequested?() })
        ]
        
        var yPos: CGFloat = 40
        for item in items {
            let itemRect = CGRect(x: 10, y: yPos, width: 80, height: 75)
            let isCurrent: Bool
            switch (currentState, item.state) {
            case (.home, .home), (.settings, .settings):
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
            let iconFont = UIFont.systemFont(ofSize: 28)
            let iconAttr: [NSAttributedString.Key: Any] = [.font: iconFont, .foregroundColor: UIColor.white]
            let iconSize = (item.icon as NSString).size(withAttributes: iconAttr)
            (item.icon as NSString).draw(at: CGPoint(x: itemRect.midX - iconSize.width / 2, y: itemRect.minY + 10), withAttributes: iconAttr)
            
            // Draw Label
            let labelFont = UIFont.systemFont(ofSize: 13, weight: .bold)
            let labelAttr: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: isCurrent ? UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 1.0) : UIColor.white.withAlphaComponent(0.8)]
            let labelSize = (item.title as NSString).size(withAttributes: labelAttr)
            (item.title as NSString).draw(at: CGPoint(x: itemRect.midX - labelSize.width / 2, y: itemRect.minY + 46), withAttributes: labelAttr)
            
            zones.append(ClickableZone(rect: itemRect, action: item.action))
            yPos += 95
        }
        
        return zones
    }
    
    private func drawTopBar(in rect: CGRect, ctx: CGContext) {
        let topBarRect = CGRect(x: rect.minX, y: 0, width: rect.width, height: 60)
        UIColor(white: 1.0, alpha: 0.03).setFill()
        UIBezierPath(rect: topBarRect).fill()
        
        // Title
        let titleFont = UIFont.systemFont(ofSize: 20, weight: .heavy)
        let titleAttr: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.white]
        let titleText: String
        switch currentState {
        case .home: titleText = "MadhurVision OS • Spatial Hub"
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
    }
    
    private func drawHomeView(in rect: CGRect, ctx: CGContext) -> [ClickableZone] {
        var zones: [ClickableZone] = []
        
        // 1. Header Hero Banner
        let heroRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 90)
        let heroPath = UIBezierPath(roundedRect: heroRect, cornerRadius: 18)
        UIColor(red: 0.08, green: 0.12, blue: 0.25, alpha: 0.6).setFill()
        heroPath.fill()
        UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.3).setStroke()
        heroPath.lineWidth = 1
        heroPath.stroke()
        
        let heroTitle = "🎬 Direct Metal Spatial Cinema Theater"
        let heroTitleAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: UIColor.white]
        (heroTitle as NSString).draw(at: CGPoint(x: heroRect.minX + 24, y: heroRect.minY + 18), withAttributes: heroTitleAttr)
        
        let heroSub = "Instant 60/120 FPS hardware decoded video streaming with zero WebKit overhead & zero lag."
        let heroSubAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.85)]
        (heroSub as NSString).draw(at: CGPoint(x: heroRect.minX + 24, y: heroRect.minY + 52), withAttributes: heroSubAttr)
        
        // 2. Video Card Grid (2 rows x 3 cols)
        let gridY = heroRect.maxY + 24
        let cardWidth: CGFloat = (rect.width - 40) / 3.0
        let cardHeight: CGFloat = 270
        let spacing: CGFloat = 20
        
        for (index, item) in cinemaCatalog.prefix(6).enumerated() {
            let row = CGFloat(index / 3)
            let col = CGFloat(index % 3)
            let cardRect = CGRect(
                x: rect.minX + col * (cardWidth + spacing),
                y: gridY + row * (cardHeight + spacing),
                width: cardWidth,
                height: cardHeight
            )
            
            // Card Background Gradient
            let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 18)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let cColors = item.gradientColors.map { $0.cgColor }
            if let cGrad = CGGradient(colorsSpace: colorSpace, colors: cColors as CFArray, locations: [0.0, 1.0]) {
                ctx.saveGState()
                cardPath.addClip()
                ctx.drawLinearGradient(cGrad, start: CGPoint(x: cardRect.minX, y: cardRect.minY), end: CGPoint(x: cardRect.maxX, y: cardRect.maxY), options: [])
                ctx.restoreGState()
            }
            
            // Glowing border
            UIColor(white: 1.0, alpha: 0.15).setStroke()
            cardPath.lineWidth = 1.5
            cardPath.stroke()
            
            // Video Thumbnail Area
            let thumbRect = CGRect(x: cardRect.minX + 12, y: cardRect.minY + 12, width: cardRect.width - 24, height: 140)
            let thumbPath = UIBezierPath(roundedRect: thumbRect, cornerRadius: 12)
            UIColor(white: 0.0, alpha: 0.4).setFill()
            thumbPath.fill()
            
            // Icon & Category Tag
            let iconFont = UIFont.systemFont(ofSize: 42)
            let iAttr: [NSAttributedString.Key: Any] = [.font: iconFont, .foregroundColor: UIColor.white]
            let iSize = (item.icon as NSString).size(withAttributes: iAttr)
            (item.icon as NSString).draw(at: CGPoint(x: thumbRect.midX - iSize.width / 2, y: thumbRect.midY - iSize.height / 2), withAttributes: iAttr)
            
            let tagRect = CGRect(x: thumbRect.minX + 8, y: thumbRect.maxY - 28, width: 100, height: 20)
            UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.3).setFill()
            UIBezierPath(roundedRect: tagRect, cornerRadius: 6).fill()
            let tagAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: UIColor.white]
            (item.category as NSString).draw(at: CGPoint(x: tagRect.minX + 6, y: tagRect.minY + 3), withAttributes: tagAttr)
            
            // Video Title
            let tFont = UIFont.systemFont(ofSize: 14, weight: .bold)
            let tAttr: [NSAttributedString.Key: Any] = [.font: tFont, .foregroundColor: UIColor.white]
            let titleBounding = CGRect(x: cardRect.minX + 14, y: thumbRect.maxY + 10, width: cardRect.width - 28, height: 40)
            (item.title as NSString).draw(in: titleBounding, withAttributes: tAttr)
            
            // Channel & Play Button
            let chFont = UIFont.systemFont(ofSize: 12)
            let chAttr: [NSAttributedString.Key: Any] = [.font: chFont, .foregroundColor: UIColor.white.withAlphaComponent(0.6)]
            (item.channel as NSString).draw(at: CGPoint(x: cardRect.minX + 14, y: cardRect.maxY - 35), withAttributes: chAttr)
            
            let playBtnRect = CGRect(x: cardRect.maxX - 85, y: cardRect.maxY - 42, width: 72, height: 28)
            UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 0.9).setFill()
            let pPath = UIBezierPath(roundedRect: playBtnRect, cornerRadius: 14)
            pPath.fill()
            let pAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: UIColor.black]
            let pText = "▶ Play"
            let pSize = (pText as NSString).size(withAttributes: pAttr)
            (pText as NSString).draw(at: CGPoint(x: playBtnRect.midX - pSize.width / 2, y: playBtnRect.midY - pSize.height / 2), withAttributes: pAttr)
            
            // Action
            zones.append(ClickableZone(rect: cardRect, action: { [weak self] in
                self?.startCinemaStream(item: item)
            }))
        }
        
        return zones
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
        
        // Left dock items (Home & Exit Cinema)
        let dockWidth: CGFloat = 100
        let homeZone = ClickableZone(rect: CGRect(x: 0, y: 40, width: dockWidth, height: 80), action: { [weak self] in
            self?.exitCinemaMode()
        })
        zones.append(homeZone)
        
        // Top HUD Overlay: Close Theater Button (top right)
        let closeRect = CGRect(x: VRMonitorNode.canvasWidth - 160, y: 15, width: 140, height: 45)
        let closeZone = ClickableZone(rect: closeRect, action: { [weak self] in
            self?.exitCinemaMode()
        })
        zones.append(closeZone)
        
        // Play / Pause Zone (center tap anywhere on the screen)
        let screenCenterRect = CGRect(x: 200, y: 100, width: VRMonitorNode.canvasWidth - 400, height: VRMonitorNode.canvasHeight - 200)
        let playPauseZone = ClickableZone(rect: screenCenterRect, action: { [weak self] in
            self?.togglePlayPauseCinema()
        })
        zones.append(playPauseZone)
        
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
