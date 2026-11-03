import Foundation

public struct PlaybackStatus: Sendable {
    public var state = "starting"
    public var time = 0.0
    public var duration = 0.0
    public var error: String?
}

/// Hands a video link to the TV's own player. The Mac only sends commands, so nothing is
/// captured or encoded and its load stays near zero.
public final class DirectPlayback {
    public let title: String
    public var onChange: ((PlaybackStatus) -> Void)?
    private var links: [String]
    private let start: Double
    private let relay: StreamRelay?
    private let server: WebSocketServer
    private let lock = NSLock()
    private var current = PlaybackStatus()
    private var attempt = 0

    public var status: PlaybackStatus { lock.withLock { current } }

    /// `links` are tried in order. Pages often expose several, and the first can be an ad or a preview.
    public init(host: String, links: [String], title: String, start: Double, relay: StreamRelay?) {
        self.links = links
        self.title = title
        self.start = start
        self.relay = relay
        server = WebSocketServer(allowedHost: host)
    }

    public func begin() throws {
        server.onText = { [weak self] in self?.handle($0) }
        try relay?.start()
        try server.start()
    }

    private func sendNext() {
        attempt += 1
        send(["type": "direct", "url": links[0], "title": title, "start": start, "attempt": attempt])
    }

    private func failureMessage(_ fallback: String) -> String {
        switch relay?.lastFailure {
        case 401, 403: "The site refused to send this video to the TV. Cast its window from Throwcast instead."
        case 404, 410: "This video link has expired. Reload the page and try again."
        case let code?: "The site returned error \(code). Cast its window from Throwcast instead."
        case nil: fallback
        }
    }

    public func stop() {
        send(["type": "directStop"])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [server, relay] in
            server.stop()
            relay?.stop()
        }
    }

    public func control(_ action: String, seconds: Double?) {
        send(["type": "directControl", "action": action, "seconds": seconds ?? 0])
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        server.sendText(String(decoding: data, as: UTF8.self))
    }

    func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "hello":
            sendNext()
        case "ping":
            break
        case "playback":
            guard message["attempt"] as? Int == attempt else { return }
            let next = lock.withLock {
                // A finished failure stays visible, whatever the idle player reports after it.
                if current.state == "failed" { return current }
                current.state = message["state"] as? String ?? current.state
                current.time = message["time"] as? Double ?? current.time
                current.duration = message["duration"] as? Double ?? current.duration
                return current
            }
            onChange?(next)
        case "playerError":
            // A failing player can report one error several times. Only the current link's first report counts.
            guard message["attempt"] as? Int == attempt, !links.isEmpty else { return }
            links.removeFirst()
            if !links.isEmpty { return sendNext() }
            let reason = failureMessage(message["message"] as? String ?? "The TV couldn't play this video.")
            let next = lock.withLock {
                current.state = "failed"
                current.error = reason
                return current
            }
            onChange?(next)
        default: break
        }
    }
}
