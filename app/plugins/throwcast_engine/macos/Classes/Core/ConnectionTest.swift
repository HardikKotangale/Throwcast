import Foundation

public struct ConnectionResult: Sendable {
    public let rttMs: Double
    public let mbps: Double

    /// Video needs headroom on Wi-Fi, so suggest 60% of what the link carried, in 5 Mbps steps.
    public var recommendedMbps: Int {
        min(100, max(5, Int(mbps * 0.6) / 5 * 5))
    }
}

/// Measures the real path to the TV app: round trip first, then as much data as it can take for 3 seconds.
public final class ConnectionTest {
    private static let seconds = 3.0
    private static let chunk = Data(count: 256 * 1024)

    private let server: WebSocketServer
    private let done: (Result<ConnectionResult, Error>) -> Void
    private let queue = DispatchQueue(label: "throwcast.test", qos: .userInitiated)
    private let lock = NSLock()
    private var rtts: [Double] = []
    private var finished = false

    public init(host: String, done: @escaping (Result<ConnectionResult, Error>) -> Void) {
        server = WebSocketServer(allowedHost: host)
        self.done = done
    }

    public func start() {
        server.onText = { [weak self] in self?.handle($0) }
        do {
            try server.start()
        } catch {
            finish(.failure(error))
            return
        }
        queue.asyncAfter(deadline: .now() + 20) { [self] in finish(.failure(CastError.timedOut)) }
    }

    private func finish(_ result: Result<ConnectionResult, Error>) {
        guard lock.withLock({ let was = finished; finished = true; return !was }) else { return }
        server.stop()
        done(result)
    }

    private func ping() {
        server.sendText(#"{"type":"ping","t":\#(Date().timeIntervalSince1970)}"#)
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "hello":
            server.sendText(#"{"type":"test"}"#)
            for index in 0 ..< 3 { queue.asyncAfter(deadline: .now() + 0.1 * Double(index)) { [self] in ping() } }
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in blast() }
        case "pong":
            if let sent = message["t"] as? Double {
                lock.withLock { rtts.append((Date().timeIntervalSince1970 - sent) * 1000) }
            }
        case "testResult":
            guard let bytes = message["bytes"] as? Double, let ms = message["ms"] as? Double, ms > 0 else {
                finish(.failure(CastError.timedOut))
                return
            }
            let rtt = lock.withLock { rtts.sorted()[safe: rtts.count / 2] ?? 0 }
            finish(.success(ConnectionResult(rttMs: rtt, mbps: bytes * 8 / ms / 1000)))
        default: break
        }
    }

    private func blast() {
        let packet = Wire.packet(kind: Wire.test, key: false, pts: 0, payload: Self.chunk)
        let end = Date().addingTimeInterval(Self.seconds)
        while Date() < end {
            if server.inflightBytes < 2 * 1024 * 1024 {
                server.sendBinary(packet)
            } else {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        server.sendText(#"{"type":"testEnd"}"#)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
