"""
╔══════════════════════════════════════════════════════════════════╗
║             MADHUR VISION — VIRTUAL VR HDMI MONITOR             ║
║                  Zero-Bloat PC Desktop Streamer                 ║
║                                                                  ║
║  • Captures Windows Desktop at 60 FPS via hardware DXGI/MSS      ║
║  • Streams directly to iPhone over USB / Wi-Fi                   ║
║  • NO webcam, NO hand tracking, NO voice recognition             ║
║  • Pure 100-inch Virtual VR Monitor for your Laptop              ║
╚══════════════════════════════════════════════════════════════════╝
"""

import socket
import threading
import struct
import time
import cv2
import numpy as np
import mss
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s │ %(levelname)-7s │ %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger("VRMonitorServer")

# Global latest JPEG buffer for HTTP / TCP streaming
latest_jpeg_frame = None
frame_lock = threading.Lock()
is_running = True

TCP_PORT = 8081
HTTP_PORT = 8082

def get_local_ips():
    """Find all local IPv4 addresses (Wi-Fi, Ethernet, Apple USB)."""
    ips = []
    try:
        hostname = socket.gethostname()
        for ip in socket.gethostbyname_ex(hostname)[2]:
            if not ip.startswith("127."):
                ips.append(ip)
    except Exception:
        pass
    return ips

# MARK: - Desktop Capture Thread (60 FPS)
def screen_capture_loop():
    global latest_jpeg_frame, is_running
    logger.info("Starting Ultra-Fast Desktop Screen Capture...")
    
    with mss.mss() as sct:
        # Monitor 1 is primary display
        monitor = sct.monitors[1] if len(sct.monitors) > 1 else sct.monitors[0]
        logger.info(f"Capturing Display: {monitor['width']}x{monitor['height']}")
        
        target_fps = 60
        interval = 1.0 / target_fps
        
        while is_running:
            start_time = time.perf_counter()
            
            # 1. Grab raw desktop frame
            img = np.array(sct.grab(monitor)) # BGRA
            
            # 2. Resize to optimal 1080p / 720p VR streaming resolution (1440x810 or 1280x720)
            target_w = 1440
            target_h = int(monitor['height'] * (1440.0 / monitor['width']))
            if target_h % 2 != 0:
                target_h += 1
                
            frame = cv2.resize(img, (target_w, target_h), interpolation=cv2.INTER_AREA)
            
            # 3. Convert BGRA to BGR
            bgr = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)
            
            # 4. Fast JPEG compression (Quality: 75 for crystal clear text & low bandwidth)
            _, encoded = cv2.imencode('.jpg', bgr, [cv2.IMWRITE_JPEG_QUALITY, 75])
            jpeg_bytes = encoded.tobytes()
            
            with frame_lock:
                latest_jpeg_frame = jpeg_bytes
                
            # Maintain 60 FPS
            elapsed = time.perf_counter() - start_time
            sleep_time = interval - elapsed
            if sleep_time > 0:
                time.sleep(sleep_time)

# MARK: - Native TCP Socket Server (For MadhurVision iOS App)
def tcp_server_loop():
    global is_running
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', TCP_PORT))
    server.listen(2)
    logger.info(f"Native TCP VR Server listening on 0.0.0.0:{TCP_PORT}")
    
    while is_running:
        try:
            client, addr = server.accept()
            logger.info(f"🚀 iPhone connected from {addr}!")
            
            # Set TCP_NODELAY for 0ms latency
            client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            
            while is_running:
                with frame_lock:
                    data = latest_jpeg_frame
                    
                if data:
                    try:
                        # Send 4 bytes length prefix + JPEG data
                        length = len(data)
                        client.sendall(struct.pack('<I', length) + data)
                    except (BrokenPipeError, ConnectionResetError, socket.error):
                        logger.info(f"iPhone {addr} disconnected.")
                        break
                        
                time.sleep(0.016) # ~60 FPS
                
            client.close()
        except Exception as e:
            if is_running:
                logger.error(f"TCP accept error: {e}")

# MARK: - HTTP MJPEG Streamer (For instant browser / fallback view)
class MJPEGHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/' or self.path == '/stream':
            self.send_response(200)
            self.send_header('Content-type', 'multipart/x-mixed-replace; boundary=--jpgboundary')
            self.end_headers()
            
            while is_running:
                with frame_lock:
                    data = latest_jpeg_frame
                    
                if data:
                    try:
                        self.wfile.write(b"--jpgboundary\r\n")
                        self.send_header('Content-type', 'image/jpeg')
                        self.send_header('Content-length', str(len(data)))
                        self.end_headers()
                        self.wfile.write(data)
                        self.wfile.write(b"\r\n")
                    except Exception:
                        break
                time.sleep(0.016)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass # Suppress HTTP access logs for clean console

def http_server_loop():
    httpd = HTTPServer(('0.0.0.0', HTTP_PORT), MJPEGHandler)
    logger.info(f"HTTP MJPEG Stream available on http://0.0.0.0:{HTTP_PORT}/stream")
    httpd.serve_forever()

# MARK: - Main Launcher
def main():
    print("=" * 65)
    print("      MADHUR VISION — VIRTUAL VR HDMI MONITOR (NO AI BLOAT)")
    print("=" * 65)
    print("  • Camera/Webcam:  DISABLED (0% Laptop Camera Usage)")
    print("  • Hand Tracking:  DISABLED (Use your laptop Keyboard/Mouse)")
    print("  • Microphone:     DISABLED (0% Audio Overhead)")
    print("  • Screen Mirror:  60 FPS Hardware Windows Desktop Mirror")
    print("=" * 65)
    print("  📱 Connect your iPhone via:")
    
    ips = get_local_ips()
    for ip in ips:
        if ip.startswith("172.20.10."):
            print(f"     ⚡ USB Cable (Recommended):  {ip}")
        else:
            print(f"     📶 Wi-Fi:                   {ip}")
            
    print(f"  🔌 TCP Port: {TCP_PORT}")
    print(f"  🌐 Browser Preview URL: http://{ips[0] if ips else 'localhost'}:{HTTP_PORT}/stream")
    print("=" * 65)
    print("  Press Ctrl+C to stop.\n")
    
    # 1. Start Screen Capture Thread
    t_cap = threading.Thread(target=screen_capture_loop, daemon=True)
    t_cap.start()
    
    # 2. Start TCP Streaming Thread
    t_tcp = threading.Thread(target=tcp_server_loop, daemon=True)
    t_tcp.start()
    
    # 3. Start HTTP Streaming Thread
    t_http = threading.Thread(target=http_server_loop, daemon=True)
    t_http.start()
    
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nStopping Virtual Display Server...")

if __name__ == "__main__":
    main()
