import Foundation
import PetCore

enum PetPoseDecision {
    static func resolve(presentation: PetPresentation, now: Date,
                        lastInteraction: Date, lastActivity: Date, pokeUntil: Date,
                        dragging: Bool, demoPose: PetPose?) -> PetPose {
        var pose = presentation.pose
        if pose == .idle, now.timeIntervalSince(max(lastInteraction, lastActivity)) >= 60 { pose = .sleeping }
        if now < pokeUntil { pose = .poke }
        if dragging { pose = .drag }
        if let demoPose { pose = demoPose }
        return pose
    }
}
