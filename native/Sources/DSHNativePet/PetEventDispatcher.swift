import Foundation
import PetCore

/// IPC 在串行队列发出事件；主队列入口保留替换连接时的 disconnect → snapshot 顺序。
struct PetEventDispatcher: Sendable {
    enum Event: Sendable {
        case message(BridgeMessage)
        case disconnect(String)
        case listenerError(String)
        case ready
    }
    private let receive: @MainActor @Sendable (Event) -> Void

    @MainActor
    init(store: PetStore,
         onUpdate: @escaping @MainActor @Sendable (Event) -> Void = { _ in },
         onError: @escaping @MainActor @Sendable (String) -> Void = { _ in },
         onReady: @escaping @MainActor @Sendable () -> Void = {}) {
        receive = { event in
            switch event {
            case let .message(.snapshot(snapshot)): store.apply(snapshot)
            case let .message(.activity(activity)): store.apply(activity)
            case .message(.heartbeat): break
            case let .disconnect(sourceID): store.disconnect(sourceID: sourceID)
            case let .listenerError(error): onError(error)
            case .ready: onReady()
            }
            onUpdate(event)
        }
    }

    func enqueue(_ event: Event) {
        DispatchQueue.main.async { receive(event) }
    }
}
