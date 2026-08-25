# MadhurVision: Standalone Mixed Reality Headset
## Complete Research, Engineering Documentation & System Architecture Specification

---

## 1. Executive Summary & Project Vision

### 1.1 The Ultimate Objective
**MadhurVision** is a next-generation, independent **Standalone Mixed Reality (MR) / Spatial Computing Headset**. 

The goal is to transition from the current **Simulation & Software Prototyping Phase** (built on Python, iOS SceneKit, and WebGL) into a **Custom Physical Headset** powered by a dedicated, customized **Android Open Source Project (AOSP)** operating system and the **OpenXR** native standard.

### 1.2 Core Operating Principle
Unlike traditional tethered headsets or simple VR viewers, MadhurVision is designed around an **Ultra-Low-Latency Video See-Through (VST) Passthrough Engine**:
1. **Camera Stream as Base Reality**: High-framerate stereoscopic cameras capture the real world.
2. **Real-Time Lens & Reprojection Processing**: Raw camera frames are hardware-undistorted and mapped to the user’s exact inter-pupillary perspective in real-time.
3. **Floating Spatial OS Layer**: The custom MadhurVision Operating System, applications, 3D windows, browser nodes, and media players float dynamically locked in 3D 6DoF physical space.
4. **Natural AI Hand Interaction**: Zero physical controllers required. High-speed computer vision running on on-device NPUs tracks hand landmarks, enabling precise laser pointing, index-thumb pinching, spatial window grabbing, and virtual air-typing.

```
+-------------------------------------------------------------------------+
|                         MADHURVISION SPATIAL OS                         |
|   +-----------------------------------------------------------------+   |
|   |   Floating Spatial Windows / Native Apps / Cinema / Browser     |   |
|   +-----------------------------------------------------------------+   |
|   |         AI Hand Tracking & Gesture Interaction Engine           |   |
|   +-----------------------------------------------------------------+   |
|   |           Spatial Compositor & 6DoF Window Manager              |   |
+-------------------------------------------------------------------------+
|                  REAL-TIME STEREO PASSTHROUGH ENGINE                    |
|   Dual Low-Latency Cameras -> Lens Correction -> Zero-Copy GPU DMA      |
+-------------------------------------------------------------------------+
|                   CUSTOM AOSP KERNEL & HARDWARE HAL                     |
|           Snapdragon XR2 / RK3588 -> Vulkan -> Fast-LCD / Micro-OLED    |
+-------------------------------------------------------------------------+
```

---

## 2. Hardware Architecture & Bill of Materials (BOM)

To achieve a true standalone form-factor comparable to commercial spatial computers, the target hardware architecture is structured as follows:

```
                      +-----------------------------+
                      |     Battery (Rear Strap)    |
                      |   5000 mAh / 20W PD / PMIC  |
                      +--------------+--------------+
                                     |
+------------------------------------+------------------------------------+
|                         MAIN COMPUTE BOARD                              |
|                                                                         |
|  +------------------------+  +-------------------+  +----------------+  |
|  | Main SoC:              |  | Memory / Storage: |  | Connectivity:  |  |
|  | Qualcomm Snapdragon    |  | 8GB/12GB LPDDR5   |  | Wi-Fi 6E / 7   |  |
|  | XR2 Gen 2 / RK3588S    |  | 128GB/256GB UFS3.1|  | Bluetooth 5.3  |  |
|  | (Octa-core CPU + Adreno|  +-------------------+  +----------------+  |
|  | GPU + 15-45 TOPS NPU)  |                                             |
|  +-----------+------------+                                             |
|              |                                                          |
|  +-----------+------------+  +-------------------+  +----------------+  |
|  | IMU Sensor:            |  | Audio Subsystem:  |  | Thermal:       |  |
|  | Dual 6-Axis Bosch      |  | Dual Spatial Spkrs|  | Ultra-quiet    |  |
|  | BMI270 / ICM-42688     |  | Dual Beamforming  |  | Centrifugal Fan|  |
|  | (1000 Hz Sampling)     |  | Microphones       |  | + Heatpipe     |  |
|  +------------------------+  +-------------------+  +----------------+  |
+------------------------------------+------------------------------------+
                                     |
        +----------------------------+----------------------------+
        |                                                         |
+-------+-------------------------+     +-------------------------+-------+
|          LEFT EYE DISPLAY       |     |         RIGHT EYE DISPLAY       |
|  2.5" Fast-LCD / Micro-OLED     |     |  2.5" Fast-LCD / Micro-OLED     |
|  2160 x 2160 @ 90Hz / 120Hz     |     |  2160 x 2160 @ 90Hz / 120Hz     |
|  MIPI-DSI Interface             |     |  MIPI-DSI Interface             |
|  3-Element Pancake Optical Lens |     |  3-Element Pancake Optical Lens |
+---------------------------------+     +---------------------------------+
        |                                                         |
        +----------------------------+----------------------------+
                                     |
+------------------------------------+------------------------------------+
|                          CAMERA & SENSOR ARRAY                          |
|                                                                         |
|  +--------------------------------+  +-------------------------------+  |
|  | 2x Passthrough RGB Cameras:    |  | 4x Tracking Cameras:          |  |
|  | Sony IMX586 / OmniVision 16MP  |  | Global Shutter VGA / 720p     |  |
|  | 120 FPS / Low-Light Optimized  |  | 120 FPS IR/Monochrome (SLAM & |  |
|  | Ultra-Wide 110-Degree FOV      |  | Hand Landmark Tracking)       |  |
|  +--------------------------------+  +-------------------------------+  |
+-------------------------------------------------------------------------+
```

### 2.1 Hardware Component Breakdown

| Component | Target Specification | Role & Technical Justification |
| :--- | :--- | :--- |
| **Main SoC** | Qualcomm Snapdragon XR2 Gen 2 *(Alt: Rockchip RK3588S)* | Dedicated XR silicon with hardware tracking acceleration, low-latency camera-to-display engine (<12ms), and 32 TOPS NPU for AI models. |
| **Displays** | Dual 2.56" Fast-LCD or 1.3" 4K Micro-OLED | 2160×2160 per eye (4K+ total), 90Hz/120Hz refresh, sub-1ms pixel response time to eliminate motion blur. |
| **Optical System** | Folded 3-Element Pancake Lenses | Reduces headset depth from 120mm (Fresnel) down to 40mm, delivering edge-to-edge clarity and eliminating chromatic aberration. |
| **Passthrough Cameras** | 2x High-Speed Color RGB (120 FPS, MIPI-CSI) | Positioned at physical human eye IPD (64mm separation) to provide realistic parallax depth without visual distortion. |
| **Tracking Cameras** | 4x Global Shutter Monochrome Cameras | High-frequency SLAM head pose estimation and 3D hand tracking in all lighting conditions. |
| **IMU** | Dual 6-Axis Bosch BMI270 (1000Hz) | Sub-millisecond sensor fusion for instant head rotation response. |
| **Weight Balance** | 450g Total (50/50 Front-to-Back Distribution) | Battery mounted at the rear of the head strap to eliminate front-heavy neck strain. |

---

## 3. Real-Time Video Passthrough (VST) Engine

The biggest technical challenge in standalone mixed reality is **Motion-to-Photon Passthrough Latency**. The human brain experiences nausea if the real world lags behind head motion by more than **15-20 milliseconds**.

### 3.1 The Low-Latency Hardware Pipeline

```
[ Dual RGB Sensors (120 FPS) ]
              │ (MIPI-CSI2 Direct Transfer)
              ▼
[ ISP Hardware Image Signal Processing ] (Auto-Exposure, White Balance, Demosaic)
              │ (Zero-Copy DMA Buffer Sharing via AHardwareBuffer / dmabuf)
              ▼
[ GPU Compute / Fragment Shader ]
   ├── 1. Lens Barrel/Pincushion Undistortion Mapping
   ├── 2. Stereo Depth Homography & Parallax Warping
   └── 3. Alpha-Blend Compositing with Virtual 3D Scene
              │ (Direct Scanout to Display Controller)
              ▼
[ Fast-LCD / Micro-OLED Panels (120Hz) ]  <── Total Pipeline Latency: < 12ms
```

### 3.2 Key Algorithmic Insights Discovered in Prototyping
1. **Zero-Copy Memory Passing**: Camera frames must NEVER be copied across memory spaces. By utilizing Linux `dmabuf` and Android `AHardwareBuffer`, the camera ISP writes directly into memory that Vulkan / OpenGL ES reads as an external texture (`GL_TEXTURE_EXTERNAL_OES`).
2. **Asynchronous Late-Stage Reprojection (ATW / PTW)**:
   If the rendering engine takes 8ms to render a 3D window, the camera frame and 3D elements are warped using the latest IMU orientation at the very last microsecond before display VSync scanout.

---

## 4. Custom AOSP-Based Spatial Operating System Architecture

The software architecture of the standalone headset is built on an open-source, highly customized Android stack:

```
+─────────────────────────────────────────────────────────────────────────+
|                        MADHURVISION APPLICATION LAYER                   |
|  [ YouTube Cinema ]  [ WebXR Browser ]  [ Settings ]  [ Native 3D Apps ]|
+─────────────────────────────────────────────────────────────────────────+
|                       SPATIAL SYSTEM SERVICES & UI                      |
|  - Spatial Shell (Dock, Omnibar, Control Center, Air Keyboard)           |
|  - 3D Window Manager & Spatial Compositor Service                       |
|  - Universal Audio & Media Router Service                               |
|  - Hand Tracking & Spatial Gesture Input Method (IME)                   |
+─────────────────────────────────────────────────────────────────────────+
|                         OPENXR & GRAPHICS ENGINE                        |
|  - OpenXR 1.1 Runtime (Native C++ / Vulkan Backend)                     |
|  - Multi-Layer Stereo Compositor (Layer Quad, Cylinder, Projection)      |
|  - 1€ (OneEuro) Jitter Suppression & Biomechanical Raycast Engine       |
+─────────────────────────────────────────────────────────────────────────+
|                       ANDROID OPEN SOURCE PROJECT (AOSP)                |
|  - Custom SurfaceFlinger (Direct Spatial Texture Forwarding)            |
|  - AudioFlinger (Low-Latency OpenSL ES / AAudio Subsystem)              |
|  - Android Hardware Abstraction Layer (Camera HAL, Sensor HAL, XR HAL)  |
+─────────────────────────────────────────────────────────────────────────+
|                           LINUX / KERNEL LAYER                          |
|  - Custom Real-Time Preempt Linux Kernel (RT-PREEMPT)                   |
|  - Direct Rendering Manager (DRM / KMS Display Driver)                  |
|  - V4L2 MIPI-CSI2 Camera Drivers & NPU Acceleration Firmware            |
+─────────────────────────────────────────────────────────────────────────+
```

### 4.1 Why Android Open Source Project (AOSP)?
1. **Turnkey Hardware Driver Ecosystem**: All top XR silicon vendors (Qualcomm Snapdragon XR2, MediaTek Dimensity, Rockchip RK3588) provide turnkey Linux/Android BSPs (Board Support Packages) with direct GPU/NPU hardware drivers.
2. **Universal App Compatibility**: Standard Android 2D applications (YouTube, Chrome, Netflix, Spotify, Office, Discord) run out-of-the-box as spatial floating windows inside our 3D compositor with **zero app modifications required**.
3. **OpenXR Compliance**: AOSP easily hosts a native OpenXR runtime written in C++/Vulkan, allowing developers to build 3D VR/MR applications with Unity, Unreal Engine, and WebXR.

---

### 4.2 The 4 Core Engineering Pillars of MadhurVision Spatial OS

To transform standard AOSP into a Spatial Operating System, we replace Android's flat 2D window manager with four dedicated subsystems:

```
+─────────────────────────────────────────────────────────────────────────────+
|                     PILLAR 1: SPATIAL WINDOW COMPOSITOR                     |
|                                                                             |
|  [ 2D Android APKs ] ──> [ Virtual SurfaceTexture ] ──> [ Vulkan 3D Quad ]  |
|  (YouTube, Chrome)       (1920x1080 GPU Buffer)          (Floating in Space)|
+─────────────────────────────────────────────────────────────────────────────+
                                       │
+─────────────────────────────────────────────────────────────────────────────+
|                     PILLAR 2: REAL-TIME PASSTHROUGH SERVICE                 |
|                                                                             |
|  [ Camera Hardware ] ──> [ V4L2 / Camera HAL ] ──> [ Stereo 3D Background ] |
|  (Dual MIPI-CSI)         (Zero-Copy DMA Buffer)      (Sub-12ms Real World)  |
+─────────────────────────────────────────────────────────────────────────────+
                                       │
+─────────────────────────────────────────────────────────────────────────────+
|                     PILLAR 3: SPATIAL INPUT DAEMON (madhurvision-inputd)    |
|                                                                             |
|  [ Hand Landmark AI ] ──> [ Raycast / Pinch ] ──> [ Native MotionEvent ]    |
|  (21 3D Coordinates)      (1€ Filter Math)        (Injected into Android)   |
+─────────────────────────────────────────────────────────────────────────────+
                                       │
+─────────────────────────────────────────────────────────────────────────────+
|                     PILLAR 4: SPATIAL SYSTEM SHELL & UI                     |
|                                                                             |
|  - Floating Glassmorphic Sidebar Dock (Home, Apps, Settings, Recalibrate)   |
|  - 3D Air Keyboard Input Method (IME) with haptic/audio feedback            |
|  - Spatial Control Center (Volume, IPD, Brightness, Passthrough Toggle)     |
+─────────────────────────────────────────────────────────────────────────────+
```

#### Pillar 1: The Spatial Window Compositor (Replacing SurfaceFlinger)
* **The Problem with Stock Android**: Standard Android's `SurfaceFlinger` takes 2D surfaces and composites them directly onto a flat display framebuffer.
* **The MadhurVision Solution**:
  1. We configure Android's `WindowManagerService` to treat each running application as a virtual display (`VirtualDisplay`) or offscreen buffer (`SurfaceTexture`).
  2. The Spatial Compositor (written in C++ and Vulkan) allocates an `AHardwareBuffer` for each running app.
  3. When an app draws a frame, Vulkan maps that buffer as a texture onto a 3D polygonal mesh (planar quad or curved cylinder) positioned at arbitrary 6DoF coordinates $(x, y, z, \text{yaw}, \text{pitch}, \text{roll})$ in the user's room.
  4. Multiple apps can be opened simultaneously, resized, repositioned, and pinned in physical space around the user.

#### Pillar 2: The Real-Time Camera Passthrough System Service
* Rather than treating the camera as an application, it runs as a low-level **System Compositor Layer**.
* The dual camera feed is decoded via hardware ISP and directly bound to the background layer of the Vulkan rendering pipeline using `GL_TEXTURE_EXTERNAL_OES` or Vulkan external memory extensions.
* When the user turns their head, **Late-Stage Asynchronous Reprojection** warps the camera background and virtual windows together, guaranteeing zero motion sickness.

#### Pillar 3: Spatial Input Daemon (`madhurvision-inputd`)
* Runs as a native background Linux service with high priority.
* Captures camera frames, executes lightweight MediaPipe / TFLite models on the on-device NPU, and computes 3D hand landmarks.
* Translates hand gestures into standard Linux input events via `/dev/uinput` or Android `InputManager`:
  - **Single Finger Pointing**: Controls the system cursor hover state.
  - **Index-Thumb Pinch**: Injects `MotionEvent.ACTION_DOWN` (touch down) and `ACTION_UP` (touch up).
  - **Two-Finger Scroll**: Injects `MotionEvent.ACTION_SCROLL` / `AXIS_VSCROLL`.
  - **Fist Grab**: Translates the entire 3D window along the ray axis.
* **Result**: Any unmodified APK (YouTube, Netflix, Chrome) responds to air gestures as if the user were physically touching a giant tablet!

#### Pillar 4: Spatial System Shell & UI
* **Floating Glassmorphic Dock**: Quick access to Home, YouTube Cinema, Browser, and Settings.
* **Universal Air Keyboard (Spatial IME)**: Floating virtual keyboard that automatically appears whenever any text field receives focus across any application.
* **Control Center**: Fast sliders for IPD calibration (55–75mm), virtual screen distance (0.6m–4.5m), and passthrough opacity.

---

### 4.3 Pure Software Development & Simulation Strategy (Zero Hardware Required)

We can build and validate 100% of this Spatial Operating System today without custom headset hardware using three development tiers:

```
+─────────────────────────────────────────────────────────────────────────────+
| TIER 1: PC ANDROID EMULATOR (AVD / x86_64 AOSP)                             |
| - Run Custom AOSP Build on PC using Android Studio / QEMU                   |
| - Simulate Stereo Camera Feeds using PC Webcam / Video Test Patterns        |
| - Develop Spatial Compositor & Floating Window Management via Vulkan        |
+─────────────────────────────────────────────────────────────────────────────+
                                       │
                                       ▼
+─────────────────────────────────────────────────────────────────────────────+
| TIER 2: STANDARD ANDROID PHONE / TABLET TESTBED                             |
| - Deploy Custom Spatial Launcher & Compositor APK on any Android phone      |
| - Use Phone's Rear Camera as the Live Passthrough Layer                     |
| - Test Real-Time Hand Tracking & Gesture Injection using Phone NPU/GPU      |
+─────────────────────────────────────────────────────────────────────────────+
                                       │
                                       ▼
+─────────────────────────────────────────────────────────────────────────────+
| TIER 3: SINGLE-BOARD COMPUTER (SBC) HARDWARE LAB (RK3588 / RPi 5)           |
| - Flash Custom AOSP ROM to a low-cost ARM64 board ($80 - $130)              |
| - Connect Dual MIPI-CSI Cameras and Test Direct Hardware Passthrough        |
| - Verify OpenXR C++ Runtime and Multi-App Spatial Performance               |
+─────────────────────────────────────────────────────────────────────────────+
```

---

## 5. AI Hand Tracking & Spatial Gesture Interaction

In our software simulation, we engineered and perfected the mathematical models for controller-free hand interaction. These exact algorithms will run directly on the headset's on-device NPU.

```
       Camera Image (120 FPS)
                 │
                 ▼
    [ AI Palm Detection Model ]
                 │ (Bounding box)
                 ▼
 [ 21-Keypoint 3D Landmark Model ]
 (Wrist, Thumb, Index, Middle, Ring, Little)
                 │
                 ▼
 [ 1€ (One Euro) Adaptive Filter ]  <── Removes hand tremor without adding lag
                 │
                 ▼
     [ Biomechanical Gesture Engine ]
     ├── 1. Laser Raycasting: Bone vector projection (Index MCP -> Index Tip)
     ├── 2. Pinch Click: Index Tip + Thumb Tip distance < 0.045 with hysteresis
     ├── 3. 3D Window Dragging: Closed fist distance-to-camera tracking
     ├── 4. Two-Finger Scroll: Index + Middle parallel movement
     └── 5. Recalibration Reset: Open Palm held for 2.0 seconds
```

### 5.1 Landmark Tracking Mathematical Specification

Each hand is tracked via 21 3D coordinates $(x, y, z)$:
* **Knuckle Index**: Index MCP ($P_5$), Middle MCP ($P_9$), Ring MCP ($P_{13}$), Little MCP ($P_{17}$), Wrist ($P_0$).
* **Fingertips**: Thumb Tip ($P_4$), Index Tip ($P_8$), Middle Tip ($P_{12}$), Ring Tip ($P_{16}$), Little Tip ($P_{20}$).

#### 1. Zero-Lag Jitter Elimination: The INRIA 1€ (OneEuro) Filter
To prevent the cursor from shaking while maintaining instant reaction time when moving rapidly, the filter dynamically calculates cutoff frequency:

$$\dot{x}_k = \frac{x_k - x_{k-1}}{T_e}$$

$$\hat{x}_k = \alpha_d \dot{x}_k + (1 - \alpha_d) \hat{x}_{k-1}$$

$$f_c = f_{c,min} + \beta |\hat{x}_k|$$

$$\alpha = \frac{1}{1 + \frac{1}{2 \pi f_c T_e}}$$

* **Parameters Established**:
  - $f_{c,min} = 1.0\text{ Hz}$ (Ultra-steady resting cursor)
  - $\beta = 0.04$ (Zero latency during fast gestures)

#### 2. Biomechanical Pinch Click Hysteresis
To prevent accidental "machine-gun" clicks when the hand rotates:
* **Trigger Threshold**: $\text{Distance}(\text{ThumbTip}, \text{IndexTip}) < 0.045\text{ m}$
* **Release Lockout**: Once clicked, the click state is locked until fingers expand beyond $0.060\text{ m}$.
* **Position Freeze**: Cursor position coordinates are frozen on the exact frame of pinch engagement to prevent cursor drift during button presses.

---

## 6. Prototyping History & Experimental Findings

During our prototyping phase across Python and iOS, we solved several critical technical barriers:

| Technical Challenge | Root Cause Identified | Final Engineering Solution |
| :--- | :--- | :--- |
| **Head Tracking Calibration** | Landscape sensor coordinate misalignment caused yaw/roll cross-talk. | Implemented reference attitude matrix multiplication ($R_{\Delta} = R_{\text{current}} \cdot R_{\text{ref}}^{-1}$) for zero-calibration at any head orientation. |
| **Accidental Sideways Clicks** | Measuring thumb distance to all fingers triggered false clicks when looking at the hand edge-on. | Isolated the detection strictly to the **Thumb-to-Index Tip** vector, combined with finger curl validation relative to the wrist. |
| **Spatial Projector Scaling** | Scaling 3D monitors altered text aspect ratios and broke collision meshes. | Implemented true physical depth projection: moving the window along the camera's Z-axis based on apparent palm size. |
| **Browser Video Sandboxing** | Headless WebKit snapshotting blocks hardware-decoded DRM/MSE video layers. | Implemented dedicated Spatial Cinema embed architecture with strict origin handshakes (`baseURL`, Referrer-Policy, and OpenXR spatial surfaces). |
| **Audio Concurrency** | Camera capture sessions muted system audio due to OS-level audio routing defaults. | Configured global `AVAudioSession` with `.playback` / `.moviePlayback` and `.mixWithOthers`. |

---

## 7. Phased Implementation Roadmap: Concept to Physical Product

```
+─────────────────────────────────────────────────────────────────────────────+
| PHASE 1: SOFTWARE SIMULATION & UX VALIDATION (COMPLETED)                     |
| - 6DoF Virtual Environment & Camera Passthrough Simulation (iOS / PC)       |
| - Biomechanical Hand Tracking & Gesture Control Math                        |
| - Spatial Window Management & Spatial OS Web Architecture                   |
+─────────────────────────────────────────────────────────────────────────────+
                                       │
                                       ▼
+─────────────────────────────────────────────────────────────────────────────+
| PHASE 2: ANDROID / AOSP EMBEDDED SYSTEM BRINGUP                              |
| - Deploy Custom AOSP Build on ARM64 Developer Board (Rockchip RK3588S)      |
| - Implement Native C++ / Vulkan OpenXR Compositor Engine                    |
| - Zero-Copy V4L2 Camera Passthrough Pipeline (MIPI-CSI to SurfaceFlinger)   |
| - Compile MediaPipe Hand Tracking to Run on Edge NPU (C++ / TFLite / NNAPI) |
+─────────────────────────────────────────────────────────────────────────────+
                                       │
                                       ▼
+─────────────────────────────────────────────────────────────────────────────+
| PHASE 3: HARDWARE PROTOTYPING & OPTOMECHANICAL ASSEMBLY                     |
| - 3D Print Ergonomic Headset Enclosure with 50/50 Counterbalanced Strap     |
| - Mount Dual 2160x2160 Fast-LCD Panels with Pancake Optical Lenses          |
| - Wire MIPI-CSI Dual Passthrough Cameras + 4x Tracking Cameras              |
| - Integrate Active Heatpipe Cooling System & 5000mAh Battery Management     |
+─────────────────────────────────────────────────────────────────────────────+
                                       │
                                       ▼
+─────────────────────────────────────────────────────────────────────────────+
| PHASE 4: CUSTOM HARDWARE CARRIER BOARD & PRODUCT POLISH                      |
| - Design Custom All-In-One PCB (SoC, PMIC, Sensor Hub, Display Drivers)    |
| - Finalize MadhurVision OS Standalone ROM (OTA Updates, App Store, Settings)|
| - FCC / CE Certification & Pilot Production Run                             |
+─────────────────────────────────────────────────────────────────────────────+
```

---

## 8. Summary & Repository Architecture Reference

All core research code, gesture mathematics, and VR engines in this repository directly feed into the Phase 2 development:

* 📁 **`MadhurVision_iOS/Sources/`**: 
  - `StandaloneVRView.swift`: Real-time stereo rendering, camera rig setup, IPD adjustment.
  - `HandTrackingManager.swift`: Biomechanical hand landmark parsing and gesture logic.
  - `OneEuroFilter.swift`: High-speed adaptive jitter suppression algorithm.
  - `PassthroughManager.swift`: Low-latency camera frame streaming pipeline.
  - `VRMonitorNode.swift`: Spatial UI, 3D window generation, and web spatial integration.
  - `AirMouseServer.swift`: Wireless 6DoF controller protocol and WebSockets bridge.
* 📁 **`MadhurVision/`** (Python Engine):
  - Spatial depth calculation, MediaPipe vision models, and desktop remote streaming pipelines.

*Documented on: August 26, 2026*  
*Project: MadhurVision Standalone Spatial Computing System*
