import PetCore

/// Fully projected delivery values; sourceLabel also preserves the capture log's metadata.
struct PetNotificationContent: Equatable, Sendable {
    let id: String
    let kind: PetNoticeKind
    let sourceLabel: String
    let title: String
    let body: String
    let sound: Bool
    let threadIdentifier: String
    let userInfo: [String: String]
}
