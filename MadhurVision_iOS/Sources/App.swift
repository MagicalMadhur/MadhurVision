import SwiftUI
import Combine
import AVFoundation

@main
struct MadhurVisionApp: App {
    init() {
        AppLogger.shared.setupCrashHandlers()
        
        // Global Audio Session Configuration for HTML5 & YouTube playback
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowAirPlay, .defaultToSpeaker])
            try audioSession.setActive(true)
            AppLogger.shared.log("[App] Global AVAudioSession active with .playback & .moviePlayback")
        } catch {
            AppLogger.shared.log("[App] AVAudioSession init warning: \(error.localizedDescription)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

enum AppMode {
    case home
    case pcRemote
    case standaloneVR
}

class AppState: ObservableObject {
    @Published var currentMode: AppMode = .home
}

struct HomeView: View {
    @StateObject private var appState = AppState()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            switch appState.currentMode {
            case .home:
                VStack(spacing: 30) {
                    Text("MadhurVision")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.bottom, 20)
                    
                    Button(action: {
                        withAnimation {
                            appState.currentMode = .pcRemote
                        }
                    }) {
                        VStack(alignment: .leading) {
                            Text("🖥️ PC Remote Mode")
                                .font(.title2).bold()
                            Text("Mirror Windows desktop over USB")
                                .font(.subheadline)
                                .opacity(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(LinearGradient(gradient: Gradient(colors: [Color.blue, Color.purple]), startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .cornerRadius(15)
                    }
                    .padding(.horizontal, 40)
                    
                    Button(action: {
                        withAnimation {
                            appState.currentMode = .standaloneVR
                        }
                    }) {
                        VStack(alignment: .leading) {
                            Text("🥽 Standalone VR")
                                .font(.title2).bold()
                            Text("Native 120Hz 3D environment")
                                .font(.subheadline)
                                .opacity(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(LinearGradient(gradient: Gradient(colors: [Color.orange, Color.red]), startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .cornerRadius(15)
                    }
                    .padding(.horizontal, 40)
                }
            case .pcRemote:
                PCRemoteView(appState: appState)
            case .standaloneVR:
                StandaloneVRView(appState: appState)
            }
        }
    }
}

struct PCRemoteView: View {
    @ObservedObject var appState: AppState
    @StateObject private var network = NetworkManager.shared
    @State private var zoomScale: CGFloat = 1.35
    @State private var lensOffset: CGFloat = 34.0
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if network.isConnected {
                if let image = network.currentImage {
                    // Dual-Eye Stereo Split Screen with Optical Lens Inset & High-Def Magnification
                    HStack(spacing: 0) {
                        Image(uiImage: image)
                            .interpolation(.high)
                            .antialiased(true)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(zoomScale)
                            .offset(x: lensOffset)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        
                        Image(uiImage: image)
                            .interpolation(.high)
                            .antialiased(true)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(zoomScale)
                            .offset(x: -lensOffset)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                    .background(Color.black)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if zoomScale < 1.2 {
                                zoomScale = 1.35 // Large readable code/text
                            } else if zoomScale < 1.5 {
                                zoomScale = 1.65 // IMAX Huge
                            } else {
                                zoomScale = 1.0 // Normal Full View
                            }
                        }
                    }
                    
                    VStack {
                        HStack {
                            Button("Disconnect") {
                                network.disconnect()
                                appState.currentMode = .home
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.6))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            
                            Spacer()
                            
                            // Zoom Badge Indicator
                            Text("🔍 Zoom: \(String(format: "%.2fx", zoomScale)) (Tap screen to zoom)")
                                .font(.system(size: 13, weight: .bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.6))
                                .foregroundColor(.cyan)
                                .cornerRadius(8)
                        }
                        Spacer()
                    }
                    .padding()
                } else {
                    VStack(spacing: 15) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                            .scaleEffect(1.5)
                        Text("Connected to PC! Receiving 60 FPS Desktop stream...")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                }
            } else {
                VStack(spacing: 20) {
                    HStack {
                        Button("Back") {
                            appState.currentMode = .home
                        }
                        .foregroundColor(.blue)
                        Spacer()
                    }
                    .padding(.horizontal)
                    
                    Text("PC Remote")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(.white)
                    
                    TextField("PC IP Address", text: $network.serverIP)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 300)
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(10)
                        .keyboardType(.numbersAndPunctuation)
                        .foregroundColor(.white)
                    
                    Button(action: {
                        network.connect()
                    }) {
                        Text("Connect")
                            .frame(width: 200)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    
                    if let error = network.errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
        }
        .onAppear {
            MotionManager.shared.start()
        }
        .onDisappear {
            MotionManager.shared.stop()
            network.disconnect()
        }
    }
}
