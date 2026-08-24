import SwiftUI
import Combine

@main
struct MadhurVisionApp: App {
    init() {
        AppLogger.shared.setupCrashHandlers()
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
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if network.isConnected {
                if let image = network.currentImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .rotationEffect(.degrees(90))
                    
                    VStack {
                        HStack {
                            Button("Disconnect") {
                                network.disconnect() // We need to add this to NetworkManager
                                appState.currentMode = .home
                            }
                            .padding()
                            .background(Color.black.opacity(0.5))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding()
                } else {
                    Text("Connected. Waiting for VR stream...")
                        .foregroundColor(.white)
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
            CameraManager.shared.start()
            MotionManager.shared.start()
        }
        .onDisappear {
            CameraManager.shared.stop() // Need to add this
            MotionManager.shared.stop()
        }
    }
}
