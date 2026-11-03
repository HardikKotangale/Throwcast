import Foundation
import Network

/// Takes one browser tab's sound from the extension, as 48 kHz stereo 16-bit PCM over a local WebSocket.
/// Chrome stops playing a captured tab on the Mac, so the sound goes to the TV alone and everything
/// else on the Mac keeps its own sound. Only this Mac can connect.
final class TabAudioServer {
    static let port: UInt16 = 47124
    var onAudio: ((Data) -> Void)?
    private var listener: NWListener?
    private var connection: NWConnection?

    /// The extension is sending a tab's sound right now.
    var isConnected: Bool { connection != nil }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] incoming in self?.accept(incoming) }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ incoming: NWConnection) {
        guard case let .hostPort(host, _) = incoming.endpoint, "\(host)".split(separator: "%")[0] == "127.0.0.1" || "\(host)".split(separator: "%")[0] == "::1" else {
            return incoming.cancel()
        }
        connection?.cancel()
        connection = incoming
        incoming.stateUpdateHandler = { [weak self, weak incoming] state in
            switch state {
            case .failed, .cancelled:
                if self?.connection === incoming { self?.connection = nil }
            default: break
            }
        }
        incoming.start(queue: .main)
        receive(on: incoming)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty { self?.onAudio?(data) }
            if error == nil { self?.receive(on: connection) }
        }
    }
}
