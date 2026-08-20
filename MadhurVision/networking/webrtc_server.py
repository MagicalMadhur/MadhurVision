"""
MadhurVision — WebRTC Signaling Server
========================================
Serves a web page to iPhone Safari, establishes WebRTC peer connection,
receives video track (camera) and data channel (gyro/accelerometer).

Requires HTTPS (Safari demands it for getUserMedia).
Generate certs with: python tools/generate_ssl_cert.py
"""

import asyncio
import json
import logging
import ssl
import os
import time
from typing import Optional

import numpy as np

logger = logging.getLogger("MadhurVision.WebRTC")

# Lazy imports to allow graceful fallback
try:
    from aiohttp import web
    from aiortc import RTCPeerConnection, RTCSessionDescription, MediaStreamTrack, VideoStreamTrack
    from aiortc.contrib.media import MediaRelay
    from av import VideoFrame
    WEBRTC_AVAILABLE = True
except ImportError:
    WEBRTC_AVAILABLE = False
    logger.warning("aiortc/aiohttp not installed. WebRTC streaming disabled.")
    logger.warning("Install with: pip install aiortc aiohttp")


class ProcessedVideoTrack(VideoStreamTrack):
    """
    A video track that streams processed frames (VR SBS) back to the iPhone.
    """
    def __init__(self):
        super().__init__()
        import threading
        self._lock = threading.Lock()
        self._current_frame = np.zeros((360, 640, 3), dtype=np.uint8)

    def push_frame(self, frame_bgr: np.ndarray):
        import threading
        with self._lock:
            self._current_frame = frame_bgr

    async def recv(self):
        pts, time_base = await self.next_timestamp()
        
        # Yield to event loop to maintain ~30fps
        await asyncio.sleep(0.033)
            
        with self._lock:
            frame = self._current_frame
            
        # Create av.VideoFrame
        new_frame = VideoFrame.from_ndarray(frame, format="bgr24")
        new_frame.pts = pts
        new_frame.time_base = time_base
        return new_frame


class WebRTCServer:
    """
    WebRTC signaling server for iPhone → PC streaming.
    
    Architecture:
        1. aiohttp serves index.html to iPhone Safari via HTTPS
        2. iPhone captures rear camera via getUserMedia
        3. WebRTC peer connection established (offer/answer via REST)
        4. Video frames received → converted to OpenCV numpy arrays
        5. DeviceOrientation data received via data channel (JSON at 60Hz)
    
    Usage:
        server = WebRTCServer(camera_manager)
        await server.start()
        # ... frames are pushed to camera_manager automatically
        await server.stop()
    """

    def __init__(self, camera_manager=None):
        """
        Args:
            camera_manager: CameraManager instance to push frames to.
                           If None, frames are buffered internally.
        """
        if not WEBRTC_AVAILABLE:
            raise RuntimeError(
                "WebRTC dependencies not installed. "
                "Run: pip install aiortc aiohttp"
            )

        self._camera_manager = camera_manager
        self._app: Optional[web.Application] = None
        self._runner: Optional[web.AppRunner] = None
        self._pcs: set = set()  # Active peer connections
        self._relay = MediaRelay()
        self._latest_orientation: dict = {"yaw": 0, "pitch": 0, "roll": 0}
        self._running = False
        self._return_track: Optional[ProcessedVideoTrack] = None

        # Import settings here to avoid circular imports at module level
        from configs.settings import settings
        self._settings = settings

    async def start(self) -> None:
        """Start the HTTPS signaling server."""
        self._app = web.Application()
        self._app.router.add_get("/", self._handle_index)
        self._app.router.add_post("/offer", self._handle_offer)
        self._app.router.add_get("/health", self._handle_health)
        self._app.on_shutdown.append(self._on_shutdown)

        # SSL context
        ssl_context = self._create_ssl_context()

        self._runner = web.AppRunner(self._app)
        await self._runner.setup()

        host = self._settings.network.server_host
        port = self._settings.network.server_port

        site = web.TCPSite(
            self._runner, host, port,
            ssl_context=ssl_context
        )
        await site.start()
        self._running = True

        # Get actual local IP for easy connection
        import socket
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            local_ip = s.getsockname()[0]
            s.close()
        except Exception:
            local_ip = "127.0.0.1"

        url = f"https://{local_ip}:{port}"
        print("\n" + "="*60)
        print("📱 IPHONE CONNECTION READY 📱".center(60))
        print("="*60)
        print(f"Point your iPhone camera at this QR code to open Safari:")
        print(f"Or type this URL manually: {url}\n")
        
        try:
            import qrcode
            qr = qrcode.QRCode(version=1, box_size=10, border=1)
            qr.add_data(url)
            qr.make(fit=True)
            qr.print_ascii(tty=True)
        except Exception as e:
            print(f"Could not print QR code: {e}")
            
        print("\n(Note: Safari will say 'Not Secure' because it's a local DIY connection.")
        print(" Tap 'Show Details' -> 'visit this website' to allow camera access.)")
        print("="*60 + "\n")

    def _create_ssl_context(self) -> ssl.SSLContext:
        """Create SSL context with self-signed certificate."""
        cert_path = self._settings.network.ssl_cert_path
        key_path = self._settings.network.ssl_key_path

        if not os.path.exists(cert_path) or not os.path.exists(key_path):
            logger.warning(f"SSL cert not found at {cert_path}")
            logger.info("Generating self-signed certificate...")
            from tools.generate_ssl_cert import generate_ssl_cert
            generate_ssl_cert(cert_path, key_path)

        ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_ctx.load_cert_chain(cert_path, key_path)
        return ssl_ctx

    async def _handle_index(self, request: 'web.Request') -> 'web.Response':
        """Serve the iPhone camera capture page."""
        template_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "templates", "index.html"
        )
        with open(template_path, 'r', encoding="utf-8") as f:
            content = f.read()
        return web.Response(content_type="text/html", text=content)

    async def _handle_health(self, request: 'web.Request') -> 'web.Response':
        """Health check endpoint."""
        return web.json_response({
            "status": "ok",
            "connections": len(self._pcs),
            "orientation": self._latest_orientation
        })

    async def _handle_offer(self, request: 'web.Request') -> 'web.Response':
        """Handle WebRTC offer from iPhone and return answer."""
        params = await request.json()

        offer = RTCSessionDescription(sdp=params["sdp"], type=params["type"])

        pc = RTCPeerConnection()
        self._pcs.add(pc)

        @pc.on("connectionstatechange")
        async def on_connectionstatechange():
            logger.info(f"Connection state: {pc.connectionState}")
            if pc.connectionState == "failed" or pc.connectionState == "closed":
                await pc.close()
                self._pcs.discard(pc)

        @pc.on("track")
        def on_track(track: MediaStreamTrack):
            logger.info(f"Received track: {track.kind}")
            if track.kind == "video":
                # Start consuming video frames
                asyncio.ensure_future(self._consume_video(track))

            @track.on("ended")
            async def on_ended():
                logger.info(f"Track {track.kind} ended")

        @pc.on("datachannel")
        def on_datachannel(channel):
            logger.info(f"Data channel opened: {channel.label}")

            @channel.on("message")
            def on_message(message):
                try:
                    data = json.loads(message)
                    if "alpha" in data:
                        # Convert DeviceOrientation to yaw/pitch/roll
                        import math
                        self._latest_orientation = {
                            "yaw": math.radians(data.get("alpha", 0)),
                            "pitch": math.radians(data.get("beta", 0)),
                            "roll": math.radians(data.get("gamma", 0)),
                            "timestamp": data.get("timestamp", time.time())
                        }
                except (json.JSONDecodeError, KeyError) as e:
                    logger.debug(f"Data channel parse error: {e}")

        # Add return video track
        self._return_track = ProcessedVideoTrack()
        pc.addTrack(self._return_track)

        # Set remote description and create answer
        await pc.setRemoteDescription(offer)
        answer = await pc.createAnswer()
        await pc.setLocalDescription(answer)

        return web.json_response({
            "sdp": pc.localDescription.sdp,
            "type": pc.localDescription.type
        })

    async def _consume_video(self, track: 'MediaStreamTrack') -> None:
        """Consume video frames from WebRTC track and push to CameraManager."""
        logger.info("Started consuming video frames")

        while self._running:
            try:
                frame: VideoFrame = await asyncio.wait_for(
                    track.recv(), timeout=5.0
                )

                # Convert to numpy BGR array (OpenCV convention)
                img = frame.to_ndarray(format="bgr24")

                # Create FrameData with orientation
                from cameras.frame_buffer import FrameData
                frame_data = FrameData(
                    frame=img,
                    timestamp=time.perf_counter(),
                    orientation=self._latest_orientation.copy()
                )

                if self._camera_manager:
                    self._camera_manager.push_frame(frame_data)

            except asyncio.TimeoutError:
                logger.warning("Video frame timeout")
            except Exception as e:
                if self._running:
                    logger.error(f"Error consuming video: {e}")
                break

        logger.info("Stopped consuming video frames")

    @property
    def orientation(self) -> dict:
        """Latest device orientation (yaw, pitch, roll in radians)."""
        return self._latest_orientation.copy()

    @property
    def connection_count(self) -> int:
        """Number of active WebRTC connections."""
        return len(self._pcs)

    def push_rendered_frame(self, frame: np.ndarray) -> None:
        """Push a processed frame to the return video track."""
        if self._return_track:
            self._return_track.push_frame(frame)

    async def _on_shutdown(self, app: 'web.Application') -> None:
        """Close all peer connections on shutdown."""
        coros = [pc.close() for pc in self._pcs]
        await asyncio.gather(*coros)
        self._pcs.clear()

    async def stop(self) -> None:
        """Stop the server gracefully."""
        self._running = False
        if self._runner:
            await self._runner.cleanup()
        logger.info("WebRTC server stopped")
