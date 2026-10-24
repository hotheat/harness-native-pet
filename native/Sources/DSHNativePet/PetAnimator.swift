import AppKit
import PetCore

@MainActor
final class PetAnimator {
    private let layer: CALayer
    private var currentPose: PetPose?
    private var enabled = false
    init(layer: CALayer) { self.layer = layer }

    func render(pose: PetPose, animated: Bool) {
        guard currentPose != pose || enabled != animated else { return }
        currentPose = pose
        enabled = animated
        layer.removeAllAnimations()
        guard animated, pose != .sleeping else { return }
        let animation: CAKeyframeAnimation
        switch pose {
        case .completed, .poke:
            animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
            animation.values = [0, 9, 0, 4, 0]
            animation.duration = 0.65
        case .thinking:
            animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            animation.values = [0, -0.018, 0, 0.018, 0]
            animation.duration = 3.5
            animation.repeatCount = .infinity
        case .working:
            animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
            animation.values = [0, 2, 0]
            animation.duration = 0.9
            animation.repeatCount = .infinity
        case .waiting:
            animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
            animation.values = [0, 4, 0]
            animation.duration = 1.4
            animation.repeatCount = .infinity
        case .error:
            animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
            animation.values = [0, -3, 3, -2, 0]
            animation.duration = 0.45
        case .idle:
            animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.values = [1, 1.008, 1]
            animation.duration = 3.5
            animation.repeatCount = .infinity
        case .drag, .sleeping: return
        }
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "pet.motion")
    }

    func stop() { layer.removeAllAnimations(); enabled = false }
}
