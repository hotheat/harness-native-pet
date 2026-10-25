import AppKit
import SwiftUI
import PetCore

@MainActor
final class PetStatusModel: ObservableObject {
    @Published var summary = PetMessageProjector.emptySummary
    @Published var sessionRows: [PetMessageProjector.SessionRow] = []
    @Published var focusedSessionID: String?
    @Published var connectionError: String?
    @Published var protocolWarning: String?
    @Published var notificationAuthorization: PetNotificationAuthorization = .notDetermined
    @Published var notificationError: String?
    @Published var sourceLabels: [String] = []
    var socketPath = ""

    func update(_ state: PetPresentation) {
        sourceLabels = Array(Set(state.sessions.map(\.sourceLabel))).sorted()
        summary = PetMessageProjector.summary(state)
        sessionRows = state.sessions.map(PetMessageProjector.sessionRow)
    }
}
