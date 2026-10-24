import Foundation
import Dispatch
import Darwin
import PetCore
import PetIPC

func output(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func wire(_ message: BridgeMessage) -> [String: Any] {
    switch message {
    case .activity(let event):
        return try! JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
    case .heartbeat(let heartbeat):
        return ["type": "heartbeat", "sourceId": heartbeat.sourceId, "seq": heartbeat.seq]
    case .snapshot(let snapshot):
        let encoded = try! JSONEncoder().encode(snapshot.sessions)
        let sessions = try! JSONSerialization.jsonObject(with: encoded)
        return ["type": "snapshot", "sourceId": snapshot.sourceId, "sourceLabel": snapshot.sourceLabel,
                "seq": snapshot.seq, "sessions": sessions]
    }
}

let server = UnixSocketServer()
let shutdownQueue = DispatchQueue(label: "dsh-native-pet.smoke.shutdown")
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: shutdownQueue)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: shutdownQueue)
for source in [termination, interrupt] {
    source.setEventHandler { @Sendable [server] in
        server.stop()
        exit(0)
    }
    source.resume()
}
do {
    try server.start(onMessage: { message in output(["type": "message", "message": wire(message)]) },
                     onDisconnect: { sourceID in output(["type": "disconnect", "sourceId": sourceID]) },
                     onError: { error in
                         output(["type": "error", "error": error])
                         exit(1)
                     },
                     onReady: { output(["type": "ready", "socketPath": server.socketPath]) })
    dispatchMain()
} catch {
    output(["type": "error", "error": String(describing: error)])
    exit(1)
}
