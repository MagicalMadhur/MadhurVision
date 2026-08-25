import Foundation
import Network
import UIKit

public struct ControllerMotionInput {
    public var pitch: Float // Up/Down angle
    public var yaw: Float   // Left/Right angle
    public var roll: Float  // Tilt angle
    public var isClicking: Bool
    public var scrollDelta: Float
    public var isDragging: Bool
    public var resetRequested: Bool
    public var timestamp: TimeInterval
}

class AirMouseServer {
    static let shared = AirMouseServer()

    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private let serverQueue = DispatchQueue(label: "AirMouseServerQueue", qos: .userInteractive)

    var onControllerInput: ((ControllerMotionInput) -> Void)?
    var onControllerConnectionChanged: ((Bool) -> Void)?

    private(set) var isClientConnected = false
    private var lastInputReceivedAt: Date?

    private init() {}

    func start(port: UInt16 = 8080) {
        guard listener == nil else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let ip = self?.getLocalIPAddress() ?? "127.0.0.1"
                    AppLogger.shared.log("[AirMouseServer] Ready on http://\(ip):\(port)")
                case .failed(let error):
                    AppLogger.shared.log("[AirMouseServer] Listener failed: \(error)")
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener?.start(queue: serverQueue)
            AppLogger.shared.log("[AirMouseServer] Listener started on port \(port)")
        } catch {
            AppLogger.shared.log("[AirMouseServer] Failed to start listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for conn in activeConnections {
            conn.cancel()
        }
        activeConnections.removeAll()
        isClientConnected = false
        onControllerConnectionChanged?(false)
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            self.activeConnections.append(connection)

            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self = self, let conn = connection else { return }
                switch state {
                case .ready:
                    self.receiveData(on: conn)
                case .failed, .cancelled:
                    self.activeConnections.removeAll(where: { $0 === conn })
                    if self.activeConnections.isEmpty {
                        self.isClientConnected = false
                        DispatchQueue.main.async {
                            self.onControllerConnectionChanged?(false)
                        }
                    }
                default:
                    break
                }
            }

            connection.start(queue: self.serverQueue)
        }
    }

    private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let conn = connection else { return }

            if let data = data, !data.isEmpty {
                self.processIncomingData(data, on: conn)
            }

            if isComplete || error != nil {
                conn.cancel()
                self.activeConnections.removeAll(where: { $0 === conn })
            } else {
                self.receiveData(on: conn)
            }
        }
    }

    private func processIncomingData(_ data: Data, on connection: NWConnection) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        // 1. Handle HTTP GET request for Controller Web Page
        if text.hasPrefix("GET ") {
            let html = generateControllerHTML()
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(html.utf8.count)\r
            Access-Control-Allow-Origin: *\r
            Connection: close\r
            \r
            \(html)
            """
            if let respData = response.data(using: .utf8) {
                connection.send(content: respData, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            }
            return
        }

        // 2. Handle HTTP POST with Motion / Controller Packets
        if text.contains("POST /input") || text.contains("POST /api/input") {
            if let bodyStart = text.range(of: "\r\n\r\n") {
                let jsonString = String(text[bodyStart.upperBound...])
                parseControllerJSON(jsonString)
            }
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 2\r\n\r\nOK"
            connection.send(content: resp.data(using: .utf8), completion: .contentProcessed({ _ in
                connection.cancel()
            }))
            return
        }

        // 3. Handle Raw JSON Line Streams (e.g. from persistent socket)
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
                parseControllerJSON(trimmed)
            }
        }
    }

    private func parseControllerJSON(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let pitch = Float(json["pitch"] as? Double ?? json["p"] as? Double ?? 0.0)
        let yaw   = Float(json["yaw"] as? Double ?? json["y"] as? Double ?? 0.0)
        let roll  = Float(json["roll"] as? Double ?? json["r"] as? Double ?? 0.0)
        let click = (json["click"] as? Bool ?? json["c"] as? Bool ?? false)
        let scroll = Float(json["scroll"] as? Double ?? json["s"] as? Double ?? 0.0)
        let drag  = (json["drag"] as? Bool ?? json["d"] as? Bool ?? false)
        let reset = (json["reset"] as? Bool ?? false)

        let input = ControllerMotionInput(
            pitch: pitch,
            yaw: yaw,
            roll: roll,
            isClicking: click,
            scrollDelta: scroll,
            isDragging: drag,
            resetRequested: reset,
            timestamp: Date().timeIntervalSince1970
        )

        lastInputReceivedAt = Date()
        if !isClientConnected {
            isClientConnected = true
            DispatchQueue.main.async { [weak self] in
                self?.onControllerConnectionChanged?(true)
                AppLogger.shared.log("[AirMouseServer] External phone controller connected!")
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.onControllerInput?(input)
        }
    }

    // Check if controller is currently actively transmitting
    var isControllerActive: Bool {
        guard let last = lastInputReceivedAt else { return false }
        return Date().timeIntervalSince(last) < 1.0
    }

    // MARK: - Local IP Resolver

    func getLocalIPAddress() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "pdp_ip0" || name == "bridge100" || name == "ap1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    if name == "en0" { break } // Prefer Wi-Fi
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }

    // MARK: - Embedded Mobile Controller Web App

    private func generateControllerHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
          <title>MadhurVision — AirMouse Controller</title>
          <style>
            * { margin:0; padding:0; box-sizing:border-box; -webkit-touch-callout:none; -webkit-user-select:none; user-select:none; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
              background: #060912;
              color: #ffffff;
              width: 100vw;
              height: 100vh;
              overflow: hidden;
              display: flex;
              flex-direction: column;
              touch-action: none;
            }
            .header {
              padding: 18px 20px 14px;
              background: rgba(14, 22, 38, 0.85);
              border-bottom: 1px solid rgba(0, 212, 255, 0.25);
              display: flex;
              justify-content: space-between;
              align-items: center;
            }
            .brand { display: flex; align-items: center; gap: 10px; font-weight: 800; font-size: 17px; color: #00d4ff; }
            .status-badge {
              font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 1px;
              padding: 4px 12px; border-radius: 20px;
              background: rgba(0,245,160,0.15); color: #00f5a0; border: 1px solid #00f5a0;
            }
            .status-badge.connecting { background: rgba(255,200,0,0.15); color: #ffc800; border-color: #ffc800; }
            
            /* Main Controller Layout */
            .controller-body {
              flex: 1;
              display: flex;
              padding: 16px;
              gap: 14px;
            }
            
            /* Left: Trackpad / Trigger */
            .trackpad {
              flex: 1;
              background: radial-gradient(circle at center, #13223d 0%, #0c1527 100%);
              border: 2px solid rgba(0, 212, 255, 0.35);
              border-radius: 24px;
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              position: relative;
              box-shadow: 0 10px 40px rgba(0,0,0,0.6);
            }
            .trackpad:active {
              background: radial-gradient(circle at center, #1b325c 0%, #0f1c36 100%);
              border-color: #00d4ff;
              box-shadow: 0 0 40px rgba(0, 212, 255, 0.4);
            }
            .tp-icon { font-size: 48px; margin-bottom: 12px; }
            .tp-title { font-size: 20px; font-weight: 800; color: #00d4ff; letter-spacing: 0.5px; }
            .tp-sub { font-size: 13px; color: rgba(255,255,255,0.5); margin-top: 4px; }
            
            /* Right: Scroll Strip & Actions */
            .side-controls {
              width: 100px;
              display: flex;
              flex-direction: column;
              gap: 12px;
            }
            .scroll-strip {
              flex: 1;
              background: rgba(18, 28, 51, 0.85);
              border: 1px solid rgba(0, 212, 255, 0.25);
              border-radius: 20px;
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: space-between;
              padding: 20px 0;
              font-size: 12px;
              font-weight: 700;
              color: #00d4ff;
              letter-spacing: 1px;
            }
            .scroll-strip:active { background: rgba(0, 212, 255, 0.15); border-color: #00d4ff; }
            
            .btn-action {
              height: 70px;
              background: rgba(255,255,255,0.08);
              border: 1px solid rgba(255,255,255,0.15);
              border-radius: 18px;
              color: white;
              font-size: 13px;
              font-weight: 700;
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              gap: 4px;
              cursor: pointer;
            }
            .btn-action:active { background: #9d4edd; border-color: #d09cf7; }
            
            /* Start Permission Overlay */
            #permission-overlay {
              position: fixed; inset: 0;
              background: radial-gradient(circle at center, #0e1d35 0%, #060912 100%);
              display: flex; flex-direction: column; align-items: center; justify-content: center;
              padding: 30px; text-align: center; z-index: 9999;
            }
            #permission-overlay.hidden { display: none; }
            .btn-start {
              margin-top: 30px;
              padding: 16px 40px;
              font-size: 18px;
              font-weight: 800;
              background: linear-gradient(135deg, #00d4ff, #7b2ff7);
              border: none;
              border-radius: 50px;
              color: white;
              box-shadow: 0 10px 40px rgba(0,212,255,0.4);
              cursor: pointer;
            }
          </style>
        </head>
        <body>
        
          <div id="permission-overlay">
            <div style="font-size:56px; margin-bottom:16px;">🎮</div>
            <h2 style="font-size:26px; font-weight:800; color:#fff; margin-bottom:8px;">MadhurVision Air Controller</h2>
            <p style="color:rgba(255,255,255,0.6); max-width:320px; font-size:14px; line-height:1.5;">
              Hold this phone like a wand remote. Aim at your VR screen, tap to click, and slide to scroll!
            </p>
            <button class="btn-start" id="start-btn">Connect & Enable Gyro</button>
          </div>
        
          <div class="header">
            <div class="brand"><span>🥽</span> MadhurVision Wand</div>
            <div class="status-badge" id="status-badge">Connected (120Hz)</div>
          </div>
        
          <div class="controller-body">
            <!-- Main Click Trigger / Trackpad -->
            <div class="trackpad" id="trackpad">
              <div class="tp-icon">👆</div>
              <div class="tp-title">TAP TO CLICK</div>
              <div class="tp-sub">Hold to Drag Window</div>
            </div>
        
            <!-- Right Side Controls -->
            <div class="side-controls">
              <!-- Scroll Strip -->
              <div class="scroll-strip" id="scroll-strip">
                <div>▲ UP</div>
                <div style="font-size:20px;">📜</div>
                <div>▼ DOWN</div>
              </div>
        
              <!-- Recenter Button -->
              <div class="btn-action" id="btn-recenter">
                <span style="font-size:18px;">🎯</span>
                <span>Recenter</span>
              </div>
            </div>
          </div>
        
          <script>
            var baseAlpha = null;
            var baseBeta = null;
            var currentPitch = 0;
            var currentYaw = 0;
            var currentRoll = 0;
            var isClicking = false;
            var isDragging = false;
            var scrollDelta = 0;
            var resetRequested = false;
            
            function haptic() {
              if (navigator.vibrate) navigator.vibrate(30);
            }
            
            // Motion Tracking
            function handleOrientation(e) {
              var a = e.alpha || 0; // Compass / Yaw (0-360)
              var b = e.beta || 0;  // Pitch (-180 to 180)
              var g = e.gamma || 0; // Roll (-90 to 90)
              
              if (baseAlpha === null) {
                baseAlpha = a;
                baseBeta = b;
              }
              
              var deltaYaw = a - baseAlpha;
              if (deltaYaw > 180) deltaYaw -= 360;
              if (deltaYaw < -180) deltaYaw += 360;
              
              var deltaPitch = b - baseBeta;
              
              // Normalize angles to -1.0 to 1.0 range (FOV: +/- 45 deg)
              currentYaw = Math.max(-1.5, Math.min(1.5, -deltaYaw / 35.0));
              currentPitch = Math.max(-1.5, Math.min(1.5, deltaPitch / 35.0));
              currentRoll = g;
            }
            
            // Stream loop (60 FPS)
            function sendPacket() {
              var payload = JSON.stringify({
                p: currentPitch,
                y: currentYaw,
                r: currentRoll,
                c: isClicking,
                d: isDragging,
                s: scrollDelta,
                reset: resetRequested
              });
              
              scrollDelta = 0;
              isClicking = false;
              resetRequested = false;
              
              fetch('/api/input', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: payload,
                keepalive: true
              }).catch(function(){});
            }
            
            setInterval(sendPacket, 16); // 60Hz
            
            // Trackpad interactions
            var tp = document.getElementById('trackpad');
            var touchStartTime = 0;
            
            tp.addEventListener('touchstart', function(e) {
              e.preventDefault();
              touchStartTime = Date.now();
              haptic();
            });
            
            tp.addEventListener('touchend', function(e) {
              e.preventDefault();
              var duration = Date.now() - touchStartTime;
              if (duration < 350) {
                isClicking = true;
                haptic();
              }
              isDragging = false;
            });
            
            // Scroll strip
            var ss = document.getElementById('scroll-strip');
            var lastTouchY = null;
            
            ss.addEventListener('touchstart', function(e) {
              e.preventDefault();
              lastTouchY = e.touches[0].clientY;
            });
            
            ss.addEventListener('touchmove', function(e) {
              e.preventDefault();
              if (lastTouchY !== null) {
                var dy = e.touches[0].clientY - lastTouchY;
                scrollDelta += dy * 0.008;
                lastTouchY = e.touches[0].clientY;
              }
            });
            
            ss.addEventListener('touchend', function(e) {
              lastTouchY = null;
            });
            
            // Recenter
            document.getElementById('btn-recenter').addEventListener('click', function(e) {
              e.preventDefault();
              baseAlpha = null;
              baseBeta = null;
              resetRequested = true;
              haptic();
            });
            
            // Start overlay
            document.getElementById('start-btn').addEventListener('click', function() {
              if (typeof DeviceOrientationEvent !== 'undefined' && typeof DeviceOrientationEvent.requestPermission === 'function') {
                DeviceOrientationEvent.requestPermission().then(function(state) {
                  if (state === 'granted') {
                    window.addEventListener('deviceorientation', handleOrientation);
                    document.getElementById('permission-overlay').classList.add('hidden');
                  }
                }).catch(function(){
                  document.getElementById('permission-overlay').classList.add('hidden');
                });
              } else {
                window.addEventListener('deviceorientation', handleOrientation);
                document.getElementById('permission-overlay').classList.add('hidden');
              }
            });
          </script>
        </body>
        </html>
        """
    }
}
