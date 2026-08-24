import Foundation
import Combine
import UIKit

class MouseTrackingManager: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    static let shared = MouseTrackingManager()
    
    // Virtual position of the mouse on a 0.0 to 1.0 scale
    @Published var virtualPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published var isLeftClicking: Bool = false
    @Published var isMouseActive: Bool = false
    
    private var isLocked = false
    
    private override init() { super.init() }
    
    func start() {
        lockSystemPointer()
        setupGestures()
    }
    
    private func setupGestures() {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first else { return }
            
            // Pan gesture tracks continuous mouse movement (works without clicking when pointer is locked)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            pan.delegate = self
            window.addGestureRecognizer(pan)
            
            // Long press tracks instant mouse down / mouse up
            let click = UILongPressGestureRecognizer(target: self, action: #selector(self.handleClick(_:)))
            click.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            click.minimumPressDuration = 0.0
            click.delegate = self
            window.addGestureRecognizer(click)
        }
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        
        self.isMouseActive = true
        
        let delta = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        
        // Adjust sensitivity
        let sensitivity: CGFloat = 0.0015
        
        var newX = self.virtualPosition.x + delta.x * sensitivity
        var newY = self.virtualPosition.y + delta.y * sensitivity
        
        // Clamp to screen bounds
        newX = max(0.01, min(0.99, newX))
        newY = max(0.01, min(0.99, newY))
        
        self.virtualPosition = CGPoint(x: newX, y: newY)
    }
    
    @objc private func handleClick(_ gesture: UILongPressGestureRecognizer) {
        self.isMouseActive = true
        
        if gesture.state == .began {
            self.isLeftClicking = true
        } else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            self.isLeftClicking = false
        }
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    
    private func lockSystemPointer() {
        guard !isLocked else { return }
        isLocked = true
        
        // Swizzle prefersPointerLocked on UIViewController to hide the assistive touch mouse
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
