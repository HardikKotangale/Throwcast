import Foundation
import Network

/// The iPhone remote. A WebSocket on the local network, found with Bonjour. A phone has to be
/// approved on this Mac once (it shows a code, the Mac asks), then it keeps a token. Until then
/// it gets nothing: no state, no commands. Only the commands in `allowed` reach the engine, so a
/// phone can't make the TV fetch a link the way `/play` on the extension's port can.
public final class RemoteControl {
    public static let port: UInt16 = 47126
    public static let service = "_throwcast._tcp"
    /// What a paired phone may ask for. Everything else is dropped.
    public static let allowed: Set<String> = ["start", "stop", "screen", "windows", "tabControl", "volume", "endTab", "rescan", "selectTV", "control", "adjust", "appSetting"]
    /// Events the phone hears. Live TV frames stay on the Mac: too big and too frequent for a remote.
    public static let forwarded: Set<String> = ["state", "stats", "tabState", "direct", "windows", "screen", "tv", "remoteStatus", "look", "macSettings"]

    /// A paired phone sent a command (main queue).
    public var onCommand: (([String: Any]) -> Void)?
    /// What a phone sees as soon as it's let in (main queue).
    public var snapshot: (() -> [[String: Any]])?
    /// A new phone wants in, showing `code`. Call back with true to allow it (main queue).
    public var approve: ((_ name: String, _ code: String, _ done: @escaping (Bool) -> Void) -> Void)?

    private let queue = DispatchQueue(label: "throwcast.remote")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: (connection: NWConnection, trusted: Bool, token: String?)] = [:]
    /// Paired phones or connections changed (main queue): time to show the list again.
    public var onPhonesChanged: (() -> Void)?
    let tokens: TokenStore
    private let port: UInt16

    public init(tokens: TokenStore = TokenStore(), port: UInt16 = RemoteControl.port) {
        self.tokens = tokens
        self.port = port
    }

    public func start() throws {
        let socket = NWProtocolWebSocket.Options()
        socket.maximumMessageSize = 4 * 1024 * 1024
        socket.autoReplyPing = true
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: Self.service)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            self?.clients.values.forEach { $0.connection.cancel() }
            self?.clients = [:]
        }
    }

    /// Sends an engine event to every paired phone. Safe from any thread.
    public func broadcast(_ event: [String: Any]) {
        guard let name = event["event"] as? String, Self.forwarded.contains(name) else { return }
        var event = event
        if name == "windows", let windows = event["windows"] as? [[String: Any]] {
            // Names and app icons only: window pictures stay on the Mac.
            event["windows"] = windows.map { $0.filter { $0.key != "image" } }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        queue.async { [weak self] in
            self?.clients.values.filter(\.trusted).forEach { self?.send(data, to: $0.connection) }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        clients[id] = (connection, false, nil)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                if self?.clients.removeValue(forKey: id)?.trusted == true { self?.changed() }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return connection.cancel() }
            if let data, let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.handle(message, from: connection)
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ message: [String: Any], from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard let trusted = clients[id]?.trusted else { return }
        let cmd = message["cmd"] as? String ?? ""
        if cmd == "hello" { return hello(message, from: connection) }
        guard trusted, Self.allowed.contains(cmd) else {
            if !trusted { reply(["event": "needsPairing"], to: connection) }
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onCommand?(message) }
    }

    private func hello(_ message: [String: Any], from connection: NWConnection) {
        let name = String((message["name"] as? String ?? "iPhone").prefix(60))
        if let token = message["token"] as? String, tokens.contains(token) {
            return admit(connection, token: token)
        }
        guard let code = message["code"] as? String, code.count == 6, code.allSatisfy(\.isNumber) else {
            return reply(["event": "needsPairing"], to: connection)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let approve = self.approve else { return }
            approve(name, code) { allowed in
                self.queue.async {
                    guard allowed else { return self.reply(["event": "pairingRefused"], to: connection) }
                    let token = self.tokens.issue(for: name)
                    self.reply(["event": "paired", "token": token], to: connection)
                    self.admit(connection, token: token)
                }
            }
        }
    }

    /// On `queue`.
    private func admit(_ connection: NWConnection, token: String) {
        let id = ObjectIdentifier(connection)
        guard clients[id] != nil else { return }
        clients[id]?.trusted = true
        clients[id]?.token = token
        changed()
        reply(["event": "welcome", "mac": Host.current().localizedName ?? "Mac"], to: connection)
        DispatchQueue.main.async { [weak self] in
            let events = self?.snapshot?() ?? []
            self?.queue.async { events.forEach { self?.reply($0, to: connection) } }
        }
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in self?.onPhonesChanged?() }
    }

    /// Paired phones for the Mac app: a short id (never the token itself), the name, and whether it's connected now.
    public func phones(_ done: @escaping ([[String: Any]]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let online = Set(self.clients.values.compactMap { $0.trusted ? $0.token : nil })
            let list = self.tokens.phones.map { token, name in ["id": TokenStore.shortID(token), "name": name, "connected": online.contains(token)] as [String: Any] }
                .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
            DispatchQueue.main.async { done(list) }
        }
    }

    /// Unpairs one phone (by its short id), or every phone, and closes their connections. A phone that comes
    /// back has to show a new code and be allowed again.
    public func forget(_ id: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            let gone = self.tokens.forget(id)
            for (key, client) in self.clients where client.token.map(gone.contains) == true {
                self.reply(["event": "needsPairing"], to: client.connection)
                client.connection.cancel()
                self.clients[key] = nil
            }
            self.changed()
        }
    }

    private func reply(_ object: [String: Any], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(data, to: connection)
    }

    private func send(_ data: Data, to connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "remote", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

/// Paired phones' tokens, kept in the app's defaults. A token is 32 random bytes; forgetting
/// one (or all) unpairs those phones.
public final class TokenStore {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "remotePhones") {
        self.defaults = defaults
        self.key = key
    }

    /// Token -> phone name.
    public var phones: [String: String] { lock.withLock { defaults.dictionary(forKey: key) as? [String: String] ?? [:] } }

    public func contains(_ token: String) -> Bool { phones[token] != nil }

    public func issue(for name: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            all[token] = name
            defaults.set(all, forKey: key)
        }
        return token
    }

    public func forgetAll() { _ = forget(nil) }

    static func shortID(_ token: String) -> String { String(token.prefix(12)) }

    /// Forgets the phone whose token starts with `id`, or all of them; returns the tokens that went.
    @discardableResult public func forget(_ id: String?) -> Set<String> {
        lock.withLock {
            var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            let gone = Set(all.keys.filter { id == nil || Self.shortID($0) == id })
            gone.forEach { all[$0] = nil }
            defaults.set(all, forKey: key)
            return gone
        }
    }
}
