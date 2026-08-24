import Foundation
import GameController
import Combine
import UIKit

class MouseTrackingManager: ObservableObject {
    static let shared = MouseTrackingManager()
    
    // Virtual position of the mouse on a 0.0 to 1.0 scale
    @Published var virtualPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published var isLeftClicking: Bool = false
    @Published var isMouseActive: Bool = false
    
    private var isLocked = false
    
    private init() { }
    
    func start() {
        lockSystemPointer()
        
        NotificationCenter.default.addObserver(self, selector: #selector(mouseDidConnect), name: .GCMouseDidConnect, object: nil)
        
        if let mouse = GCMouse.current {
            setupMouse(mouse)
        }
    }
    
    @objc private func mouseDidConnect(_ notification: Notification) {
        guard let mouse = notification.object as? GCMouse else { return }
        setupMouse(mouse)
    }
    
    private func setupMouse(_ mouse: GCMouse) {
        mouse.mouseInput?.mouseMovedHandler = { [weak self] mouse, deltaX, deltaY in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isMouseActive = true
                
                // Adjust sensitivity (delta is usually in points)
                let sensitivity: CGFloat = 0.0015
                
                var newX = self.virtualPosition.x + CGFloat(deltaX) * sensitivity
                var newY = self.virtualPosition.y - CGFloat(deltaY) * sensitivity // Y is inverted in GameController
                
                // Clamp to screen bounds (0 to 1)
                newX = max(0.01, min(0.99, newX))
                newY = max(0.01, min(0.99, newY))
                
                self.virtualPosition = CGPoint(x: newX, y: newY)
            }
        }
        
        mouse.mouseInput?.leftButton.pressedChangedHandler = { [weak self] button, value, pressed in
            DispatchQueue.main.async {
                self?.isLeftClicking = pressed
                self?.isMouseActive = true
            }
        }
    }
    
    private func lockSystemPointer() {
        guard !isLocked else { return }
        isLocked = true
        
        // Swizzle prefersPointerLocked on UIViewController to completely hide the iOS assistive touch mouse
        // and lock it in place, allowing GCMouse to read raw deltas continuously.
        let originalSelector = #selector(getter: UIViewController.prefersPointerLocked)
        let swizzledSelector = #selector(getter: UIViewController.swizzled_prefersPointerLocked)
        
        guard let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzledSelector) else { return }
        
        method_exchangeImplementations(originalMethod, swizzledMethod)
        
        DispatchQueue.main.async {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                window.rootViewController?.setNeedsUpdateOfPrefersPointerLocked()
            }
        }
    }
}

extension UIViewController {
    @objc dynamic var swizzled_prefersPointerLocked: Bool {
        return true
    }
}
