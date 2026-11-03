import Foundation
import Network

/// Serves exactly one TV. The stream is the user's screen, so any other device is refused.
final class WebSocketServer {
    var onText: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?
    private let allowedHost: String
    private let queue = DispatchQueue(label: "throwcast.socket")
    private let lock = NSLock()
    private var listener: NWListener?
    private var probeListener: NWListener?
    private var connection: NWConnection?
    private var inflight = 0

    init(allowedHost: String) { self.allowedHost = allowedHost }

    /// Bytes handed to the network but not yet accepted by it. Rising means the link can't keep up.
    var inflightBytes: Int { lock.withLock { inflight } }
    var isConnected: Bool { queue.sync { connection != nil } }

    func start() throws {
        let socket = NWProtocolWebSocket.Options()
        socket.maximumMessageSize = 32 * 1024 * 1024
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Wire.port)!)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        self.listener = listener

        let probe = try NWListener(using: { let p = NWParameters.tcp; p.allowLocalEndpointReuse = true; return p }(), on: NWEndpoint.Port(rawValue: Wire.probePort)!)
        probe.newConnectionHandler = { [weak self] in self?.answerProbe($0) }
        probe.start(queue: queue)
        probeListener = probe
    }

    func stop() {
        listener?.cancel()
        listener = nil
        probeListener?.cancel()
        probeListener = nil
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
        }
    }

    private func isAllowed(_ connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        let address = "\(host)".split(separator: "%")[0].replacingOccurrences(of: "::ffff:", with: "")
        return address == allowedHost
    }

    /// Lets the TV find this Mac with a plain HTTP request. Silent to every other device.
    private func answerProbe(_ incoming: NWConnection) {
        guard isAllowed(incoming) else {
            incoming.cancel()
            return
        }
        incoming.start(queue: queue)
        incoming.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
            let reply = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            incoming.send(content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in incoming.cancel() })
        }
    }

    private func accept(_ incoming: NWConnection) {
        guard isAllowed(incoming) else {
            incoming.cancel()
            return
        }
        connection?.cancel()
        connection = incoming
        lock.withLock { inflight = 0 }
        incoming.stateUpdateHandler = { [weak self, weak incoming] state in
            guard let self, let incoming else { return }
            switch state {
            case .ready:
                self.sendText(#"{"type":"throwcast","name":"\#(Host.current().localizedName ?? "Mac")"}"#)
            case .failed, .cancelled:
                if self.connection === incoming {
                    self.connection = nil
                    self.onDisconnect?()
                }
            default: break
            }
        }
        incoming.start(queue: queue)
        receive(on: incoming)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, error == nil else { return }
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.onText?(object)
            }
            self.receive(on: connection)
        }
    }

    func sendText(_ text: String) { send(Data(text.utf8), opcode: .text) }
    func sendBinary(_ data: Data) { send(data, opcode: .binary) }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        lock.withLock { inflight += data.count }
        queue.async { [weak self] in
            guard let self else { return }
            guard let connection = self.connection else {
                self.lock.withLock { self.inflight -= data.count }
                return
            }
            let context = NWConnection.ContentContext(identifier: "frame",
                                                      metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.inflight -= data.count }
            })
        }
    }
}
