import SwiftUI
import Combine

@main
struct MadhurVisionApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
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
                        .rotationEffect(.degrees(90)) // Adjust based on landscape/portrait
                } else {
                    Text("Connected. Waiting for VR stream...")
                        .foregroundColor(.white)
                }
            } else {
                VStack(spacing: 20) {
                    Text("Madhur Vision VR")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(.white)
                    
                    Text("Connect via USB Tethering or WiFi")
                        .foregroundColor(.gray)
                    
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
    }
}
