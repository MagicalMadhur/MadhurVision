# Madhur Vision — Setup Guide

## 📋 Prerequisites

- **Python 3.10+** (3.11 recommended)
- **Windows 10/11** (for desktop integration)
- **GPU with CUDA** (optional but recommended for depth estimation)
- **iPhone** (for camera streaming via WebRTC)
- **Webcam** (alternative to iPhone for development)
- **Microphone** (for voice commands)
- **VR headset** (optional — Google Cardboard, VR Box, or DIY)

---

## 🚀 Installation

### 1. Clone / Navigate to the project

```bash
cd "d:\VIBE Code\VR\MadhurVision"
```

### 2. Create a virtual environment (recommended)

```bash
python -m venv venv
venv\Scripts\activate
```

### 3. Install dependencies

**Standard (CPU):**
```bash
pip install -r requirements.txt
```

**With GPU acceleration (recommended):**
```bash
# Install PyTorch with CUDA first
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121

# Then install the rest
pip install -r requirements.txt
```

### 4. Download Vosk model (for voice commands)

The system will auto-download on first run, or manually:
```bash
mkdir models
cd models
# Download from: https://alphacephei.com/vosk/models
# Recommended: vosk-model-small-en-us-0.15
# Extract to: models/vosk-model-small-en-us-0.15/
```

---

## 🎮 Running

### Quick Start (Webcam Mode)
```bash
python main.py
```
This starts with your local webcam, desktop mode, and all features enabled.

### VR Mode
```bash
python main.py --mode vr
```
Renders side-by-side stereo output for VR headsets.

### iPhone Camera Mode
```bash
python main.py --camera webrtc
```
Then open the displayed URL on your iPhone in **Safari**.

### Debug Mode
```bash
python main.py --mode debug
```
Shows a 4-panel debug dashboard with camera feed, depth map, gestures, and performance.

### Lightweight Mode
```bash
python main.py --no-voice --no-depth
```
Disables voice recognition and depth estimation for lower resource usage.

### Gesture Calibration
```bash
python main.py --calibrate
```
Interactive calibration for tuning gesture thresholds to your hands.

---

## 📱 iPhone Setup (WebRTC)

1. Make sure your iPhone and PC are on the **same Wi-Fi network**
2. Generate SSL certificate (required by Safari):
   ```bash
   python tools/generate_ssl_cert.py
   ```
3. Start the server:
   ```bash
   python main.py --camera webrtc
   ```
4. Note the URL printed (e.g., `https://192.168.1.100:8080`)
5. Open that URL in **Safari** on your iPhone
6. Accept the security warning (self-signed cert)
7. Tap **"Start Streaming"**
8. Grant camera permission when prompted

> **Note:** WebRTC on iOS only works in Safari. Chrome/Firefox won't work.

---

## 🖐️ Gesture Controls

| Gesture | Action |
|---------|--------|
| **Pinch** (thumb + index) | Click / Select |
| **Pinch + Move** | Drag windows |
| **Grab** (close fist) | Move window in depth |
| **Open Palm** | Release / Cancel |
| **Swipe Left** | Minimize focused window |
| **Swipe Right** | Restore last minimized |
| **Two-finger Scroll** | Scroll content |
| **Two-hand Zoom** | Resize focused window |

---

## 🗣️ Voice Commands

| Command | Action |
|---------|--------|
| "Open Chrome" | Launch Chrome browser |
| "Open YouTube" | Open YouTube in Chrome |
| "Close window" | Close focused window |
| "New window" | Create new desktop stream |
| "Move left" / "Move right" | Reposition window |
| "Minimize" | Minimize focused window |
| "Screenshot" | Capture screenshot |
| "Grid layout" | Arrange windows in grid |
| "Arc layout" | Arrange windows in arc |
| "Show desktop" | Minimize all windows |

---

## ⌨️ Keyboard Shortcuts

| Key | Action |
|-----|--------|
| **ESC** | Quit |
| **F11** | Toggle fullscreen |
| **D** | Toggle debug dashboard |

---

## 🔧 Troubleshooting

### "Camera not found"
- Check webcam is connected and not used by another app
- Try a different camera index: edit `settings.camera.local_camera_index`

### "Vosk model not found"
- Download from https://alphacephei.com/vosk/models
- Extract to `models/vosk-model-small-en-us-0.15/`

### "OpenGL shader compilation failed"
- Your GPU may not support OpenGL 3.3 Core
- The system automatically falls back to fixed-function rendering

### iPhone not connecting
- Both devices must be on the same Wi-Fi
- Use **Safari** only (not Chrome)
- Accept the self-signed certificate warning
- Check firewall allows port 8080

### Low FPS
- Disable depth estimation: `--no-depth`
- Disable voice: `--no-voice`
- Use `MiDaS_small` model (default)
- Reduce resolution in settings

---

## 📁 Project Structure

```
MadhurVision/
├── main.py              # Entry point & orchestrator
├── requirements.txt     # Dependencies
├── configs/             # Settings & calibration data
├── cameras/             # Camera abstraction & frame buffer
├── networking/          # WebRTC server & iPhone streaming
├── tracking/            # Hand & head tracking
├── gestures/            # Gesture recognition & events
├── depth/               # Monocular depth estimation
├── rendering/           # OpenGL engine & shaders
├── windows/             # Spatial window management
├── desktop/             # PyAutoGUI & screen capture
├── voice/               # Vosk voice recognition
├── vr/                  # Stereo VR output
├── ai/                  # Future AI module interfaces
├── tools/               # SSL cert gen & debug dashboard
└── tests/               # Standalone test scripts
```
