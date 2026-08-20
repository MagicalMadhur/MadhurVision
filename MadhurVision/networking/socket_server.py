import socket
import threading
import struct
import cv2
import numpy as np
import logging

logger = logging.getLogger("MadhurVision.SocketServer")

class NativeSocketServer:
    def __init__(self, camera_manager=None, port=8081):
        self._camera_manager = camera_manager
        self.port = port
        self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_socket.bind(('0.0.0.0', self.port))
        self.server_socket.listen(1)
        
        self.client_socket = None
        self.running = False
        self.thread = None
        
        self.latest_camera_frame = None
        self.latest_imu = (0.0, 0.0, 0.0) # pitch, yaw, roll
        
        self._lock = threading.Lock()

    def start(self):
        self.running = True
        self.thread = threading.Thread(target=self._accept_loop, daemon=True)
        self.thread.start()
        logger.info(f"Native iOS Socket Server listening on port {self.port}")

    def stop(self):
        self.running = False
        if self.client_socket:
            self.client_socket.close()
        self.server_socket.close()

    def _accept_loop(self):
        while self.running:
            try:
                client, addr = self.server_socket.accept()
                logger.info(f"iOS Device connected from {addr}")
                self.client_socket = client
                
                # Start reading loop
                self._receive_loop(client)
            except Exception as e:
                if self.running:
                    logger.error(f"Socket accept error: {e}")

    def _receive_loop(self, client):
        def recv_all(n):
            data = bytearray()
            while len(data) < n:
                packet = client.recv(n - len(data))
                if not packet:
                    return None
                data.extend(packet)
            return data

        while self.running:
            try:
                type_byte = recv_all(1)
                if not type_byte:
                    break
                
                msg_type = type_byte[0]
                
                if msg_type == 1: # Video Frame
                    len_bytes = recv_all(4)
                    if not len_bytes: break
                    length = struct.unpack('<I', len_bytes)[0]
                    
                    frame_data = recv_all(length)
                    if not frame_data: break
                    
                    nparr = np.frombuffer(frame_data, np.uint8)
                    frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
                    
                    if frame is not None:
                        import time
                        from cameras.frame_buffer import FrameData
                        
                        with self._lock:
                            self.latest_camera_frame = frame
                            
                        if self._camera_manager:
                            frame_data = FrameData(
                                frame=frame,
                                timestamp=time.perf_counter(),
                                orientation={
                                    "pitch": self.latest_imu[0],
                                    "yaw": self.latest_imu[1],
                                    "roll": self.latest_imu[2]
                                }
                            )
                            self._camera_manager.push_frame(frame_data)
                            
                elif msg_type == 2: # IMU Data
                    imu_data = recv_all(24)
                    if not imu_data: break
                    
                    pitch, yaw, roll = struct.unpack('<ddd', imu_data)
                    with self._lock:
                        self.latest_imu = (pitch, yaw, roll)
            except Exception as e:
                logger.error(f"Socket receive error: {e}")
                break
                
        logger.info("iOS Device disconnected")
        client.close()
        self.client_socket = None

    def get_latest_frame(self):
        with self._lock:
            return self.latest_camera_frame
            
    @property
    def orientation(self):
        with self._lock:
            return {
                "pitch": self.latest_imu[0],
                "yaw": self.latest_imu[1],
                "roll": self.latest_imu[2]
            }

    def push_rendered_frame(self, bgr_frame):
        if not self.client_socket:
            return
            
        try:
            # Compress to JPEG
            _, buffer = cv2.imencode('.jpg', bgr_frame, [cv2.IMWRITE_JPEG_QUALITY, 70])
            data = buffer.tobytes()
            
            # Send length (4 bytes) + data
            length = len(data)
            self.client_socket.sendall(struct.pack('<I', length) + data)
        except Exception as e:
            pass # Client might have disconnected
