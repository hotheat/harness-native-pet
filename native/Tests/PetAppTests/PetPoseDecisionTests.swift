import Foundation
import PetCore
import Testing
@testable import DSHNativePet

struct PetPoseDecisionTests {
    private let now = Date(timeIntervalSince1970: 1000)

    private func resolve(_ pose: PetPose = .idle, interactionAge: TimeInterval = 60,
                         activityAge: TimeInterval = 60, pokeRemaining: TimeInterval = 0,
                         dragging: Bool = false, demoPose: PetPose? = nil) -> PetPose {
        let state = PetPresentation(pose: pose, activeCount: pose == .working || pose == .thinking ? 1 : 0,
                                    waitingCount: pose == .waiting ? 1 : 0, connectedSources: 0, sessions: [], feedback: nil)
        return PetPoseDecision.resolve(presentation: state, now: now,
                                       lastInteraction: now.addingTimeInterval(-interactionAge),
                                       lastActivity: now.addingTimeInterval(-activityAge),
                                       pokeUntil: now.addingTimeInterval(pokeRemaining),
                                       dragging: dragging, demoPose: demoPose)
    }

    @Test func idleSleepsAtSixtySeconds() {
        #expect(resolve(interactionAge: 59.999, activityAge: 100) == .idle)
        #expect(resolve(interactionAge: 100, activityAge: 59.999) == .idle)
        #expect(resolve() == .sleeping)
        #expect(resolve(interactionAge: 100, activityAge: 100) == .sleeping)
    }

    @Test func recentInteractionOrActivityKeepsIdleAwake() {
        #expect(resolve(interactionAge: 0) == .idle)
        #expect(resolve(activityAge: 0) == .idle)
    }

    @Test func nonIdlePosesDoNotSleep() {
        for pose in PetPose.allCases where pose != .idle {
            #expect(resolve(pose, interactionAge: 100, activityAge: 100) == pose)
        }
    }

    @Test func pokeOverridesSleepingAndActivityUntilItsDeadline() {
        #expect(resolve(pokeRemaining: 0.001) == .poke)
        #expect(resolve(.sleeping, pokeRemaining: 1) == .poke)
        #expect(resolve(.working, pokeRemaining: 1) == .poke)
        #expect(resolve(pokeRemaining: 0) == .sleeping)
        #expect(resolve(.working, pokeRemaining: -1) == .working)
    }

    @Test func dragOverridesPokeSleepingAndActivity() {
        #expect(resolve(pokeRemaining: 1, dragging: true) == .drag)
        #expect(resolve(dragging: true) == .drag)
        #expect(resolve(.working, dragging: true) == .drag)
    }

    @Test func demoHasFinalPriority() {
        for pose in PetPose.allCases {
            #expect(resolve(pokeRemaining: 1, dragging: true, demoPose: pose) == pose)
        }
        #expect(resolve(demoPose: .idle) == .idle)
    }
}
