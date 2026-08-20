import Foundation
import Network
import SwiftUI

class NetworkManager: ObservableObject {
    static let shared = NetworkManager()
    
    @Published var isConnected = false
    @Published var serverIP = "192.168.1.100" // Default or tethering IP like 172.20.10.2
    @Published var currentImage: UIImage? = nil
    @Published var errorMessage: String? = nil
    
    private var connection: NWConnection?
    private let port: NWEndpoint.Port = 8081
    
    private let queue = DispatchQueue(label: "NetworkQueue")
    
    private init() {}
    
    func connect() {
        self.errorMessage = nil
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(serverIP), port: port)
        connection = NWConnection(to: endpoint, using: .tcp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true
                    self?.receiveVideoFrames()
                case .failed(let error):
                    self?.isConnected = false
                    self?.errorMessage = "Connection failed: \(error.localizedDescription)"
                case .waiting(let error):
                    self?.errorMessage = "Waiting: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        
        connection?.start(queue: queue)
    }
    
    func disconnect() {
        connection?.cancel()
        connection = nil
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
    
    func sendVideoFrame(data: Data) {
        guard isConnected else { return }
        
        // Packet format: [1 byte Type: 1 (Video)] [4 bytes Length] [Data]
        var type: UInt8 = 1
        var length = UInt32(data.count).littleEndian
        
        var packet = Data()
        packet.append(&type, count: 1)
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(data)
        
        connection?.send(content: packet, completion: .contentProcessed({ error in
            if let error = error {
                print("Send video error: \(error)")
            }
        }))
    }
    
    func sendIMUData(pitch: Double, yaw: Double, roll: Double) {
        guard isConnected else { return }
        
        // Packet format: [1 byte Type: 2 (IMU)] [24 bytes Data (3x Double)]
        var type: UInt8 = 2
        var p = pitch.bitPattern.littleEndian
        var y = yaw.bitPattern.littleEndian
        var r = roll.bitPattern.littleEndian
        
        var packet = Data()
        packet.append(&type, count: 1)
        withUnsafeBytes(of: &p) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &y) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &r) { packet.append(contentsOf: $0) }
        
        connection?.send(content: packet, completion: .contentProcessed({ _ in }))
    }
    
    private func receiveVideoFrames() {
        guard let connection = connection else { return }
        
        // Read exactly 4 bytes for length
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            if let data = data, data.count == 4 {
                let length = data.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
                
                // Now read the image data
                connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { imageData, _, _, _ in
                    if let imageData = imageData, let image = UIImage(data: imageData) {
                        DispatchQueue.main.async {
                            self?.currentImage = image
                        }
                    }
                    // Loop
                    self?.receiveVideoFrames()
                }
            } else if error == nil && !isComplete {
                self?.receiveVideoFrames()
            } else {
                DispatchQueue.main.async {
                    self?.isConnected = false
                    self?.errorMessage = "Disconnected"
                }
            }
        }
    }
}
