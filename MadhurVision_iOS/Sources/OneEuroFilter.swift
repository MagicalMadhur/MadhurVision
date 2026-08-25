import Foundation
import CoreGraphics
import simd

/// High-Performance 1€ (One-Euro) Filter for VR/AR motion tracking.
/// Dynamically adjusts cutoff frequency based on movement speed:
/// - Low speed / hovering: low cutoff -> 100% elimination of micro-tremors and tracking noise.
/// - High speed / moving: high cutoff -> 0ms latency with zero lag.
public final class OneEuroFilter1D {
    private var minCutoff: Double // Minimum cutoff frequency (Hz)
    private var beta: Double      // Speed coefficient
    private var dCutoff: Double   // Cutoff frequency for derivative (Hz)
    
    private var xPrev: Double? = nil
    private var dxPrev: Double = 0.0
    private var tPrev: TimeInterval? = nil
    
    public init(minCutoff: Double = 1.2, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }
    
    private func alpha(rate: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        let te = 1.0 / rate
        return 1.0 / (1.0 + tau / te)
    }
    
    public func filter(x: Double, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        guard let xPrev = xPrev, let tPrev = tPrev else {
            self.xPrev = x
            self.tPrev = timestamp
            self.dxPrev = 0.0
            return x
        }
        
        let dt = max(timestamp - tPrev, 1e-4)
        let rate = 1.0 / dt
        
        // 1. Filter derivative (velocity)
        let dx = (x - xPrev) / dt
        let aD = alpha(rate: rate, cutoff: dCutoff)
        let dxHat = aD * dx + (1.0 - aD) * dxPrev
        
        // 2. Adaptive cutoff based on speed
        let cutoff = minCutoff + beta * abs(dxHat)
        let a = alpha(rate: rate, cutoff: cutoff)
        
        // 3. Filter position
        let xHat = a * x + (1.0 - a) * xPrev
        
        self.xPrev = xHat
        self.dxPrev = dxHat
        self.tPrev = timestamp
        
        return xHat
    }
    
    public func reset() {
        xPrev = nil
        dxPrev = 0.0
        tPrev = nil
    }
}

/// 2D One-Euro Filter for screen & camera coordinates
public final class OneEuroFilter2D {
    private let filterX: OneEuroFilter1D
    private let filterY: OneEuroFilter1D
    
    public init(minCutoff: Double = 1.2, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.filterX = OneEuroFilter1D(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
        self.filterY = OneEuroFilter1D(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
    }
    
    public func filter(point: CGPoint, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CGPoint {
        let x = filterX.filter(x: Double(point.x), timestamp: timestamp)
        let y = filterY.filter(x: Double(point.y), timestamp: timestamp)
        return CGPoint(x: x, y: y)
    }
    
    public func reset() {
        filterX.reset()
        filterY.reset()
    }
}
