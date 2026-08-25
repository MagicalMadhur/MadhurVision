# 🥽 MadhurVision Spatial OS: Complete System Blueprint & Architecture

## 1. Project Overview
**MadhurVision Spatial OS** is a standalone Mixed Reality Hypervisor and 3D Operating System for Apple Silicon (iPhone 17 Pro Max). It uses stereoscopic video passthrough, 120Hz 6DoF head tracking, on-device AI hand tracking, and a floating spatial multi-window manager.

---

## 2. Directory Structure & Component Map

```
MadhurVision_SpatialOS/
├── MASTER_PROMPT.md                  # Master prompt to initialize new AI chat sessions
├── SYSTEM_BLUEPRINT.md               # Complete architectural specifications and data flows
├── project.yml                       # XcodeGen project configuration
├── Sources/
│   ├── App.swift                     # Main entrypoint & global AVAudioSession initialization
│   ├── StandaloneVRView.swift        # Stereoscopic dual-eye rendering rig & 6DoF camera engine
│   ├── PassthroughManager.swift      # Low-latency camera capture & Metal background pipeline
│   ├── HandTrackingManager.swift     # 21-Keypoint Vision landmark processing & gesture state machine
│   ├── OneEuroFilter.swift           # INRIA 1€ adaptive low-pass filter (Beta=0.04, FcMin=1.0)
│   ├── HandCursorNode.swift          # Laser beam pointer, reticle dot, and spatial click animator
│   ├── VRMonitorNode.swift           # Spatial 3D Window, YouTube Cinema Theater & WebOS Shell
│   ├── AirMouseServer.swift          # Wireless 6DoF smartphone wand protocol (WebSockets bridge)
│   └── AppLogger.swift               # Crash diagnostics & real-time telemetry logger
└── Assets/                           # App icons, sound effects, and spatial assets
```

---

## 3. Data Flow Architecture

```
                                    +─────────────────────────────+
                                    |    Dual-Eye Camera Feed     |
                                    +──────────────┬──────────────+
                                                   │ (CMSampleBuffer)
                                                   ▼
+─────────────────────────────+     +─────────────────────────────+
|    1000Hz IMU Gyroscope     |     |     PassthroughManager      |
+──────────────┬──────────────+     | (Zero-Copy Metal CGImage)   |
               │ (Delta Attitude)   +──────────────┬──────────────+
               ▼                                   │ (Background Texture)
+──────────────────────────────────────────────────┴──────────────+
|                      StandaloneVRView                           |
|       (120 FPS Stereoscopic Metal / SceneKit Compositor)        |
|                                                                 |
|   Left Camera (-IPD/2)                 Right Camera (+IPD/2)    |
|   FOV: 90°                             FOV: 90°                 |
+──────────────────────────────┬──────────────────────────────────+
                               │ (Raycasts & Screen Hits)
                               ▼
+─────────────────────────────────────────────────────────────────+
|                       VRMonitorNode                             |
|  - Floating Spatial OS Shell (Sidebar Dock, Omnibar, Settings)  |
|  - YouTube Cinema Theater Screen (Official IFrame Embed Engine) |
|  - Universal Air Keyboard (Spatial Virtual IME)                 |
+──────────────────────────────▲──────────────────────────────────+
                               │ (Pinch Clicks, Ray Targets, Scrolls)
+──────────────────────────────┴──────────────────────────────────+
|                    HandTrackingManager                          |
|  - Apple Neural Engine 21-Point Landmark Computer Vision        |
|  - INRIA 1€ Adaptive Jitter Suppression (Beta=0.04)             |
|  - Biomechanical Index-Thumb Pinch Hysteresis Logic             |
+─────────────────────────────────────────────────────────────────+
```

---

## 4. Hardware Optimization Parameters

* **Target Device**: iPhone 17 Pro Max (A-Series Pro Silicon, 120Hz ProMotion Super Retina XDR OLED).
* **Display Output**: Dual-eye side-by-side stereoscopic viewport (120 FPS target framerate).
* **Inter-Pupillary Distance (IPD)**: Default 65mm (Adjustable dynamically from 55mm to 75mm).
* **Virtual Screen Distance**: Default 2.0 meters in front of user (Adjustable from 0.6m to 4.5m).
* **Hand Tracking Distance**: 0.2m to 1.8m from front/rear camera array.
* **Click Hysteresis**: Engage at $< 0.045\text{m}$, Release unlock at $> 0.060\text{m}$.
