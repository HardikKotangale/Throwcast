import Foundation
import Network
import Observation
import UIKit

/// Something the phone can control: a Mac running Throwcast (found with Bonjour), or a TV running the
/// Throwcast app, which takes over when the browser extension casts without the Mac app.
struct Mac: Identifiable, Hashable {
    enum Kind: Hashable { case mac, tv }
    let name: String
    var endpoint: NWEndpoint
    var kind: Kind = .mac
    /// A TV's address, for trying each of its ports.
    var host: String?
    var id: String { (kind == .tv ? "tv:" : "") + name }
}

struct TVInfo: Identifiable, Hashable {
    let host: String, name: String, width: Int, height: Int
    var id: String { host }
    var resolution: String { width >= 3840 ? "4K" : width >= 2560 ? "1440p" : "\(height)p" }
}

struct WindowInfo: Identifiable, Hashable {
    let id: Int, app: String, title: String, hidden: Bool
    let icon: UIImage?
}

enum Source: String, CaseIterable, Identifiable {
    case screen, mirror, extend, window
    var id: String { rawValue }
    var label: String {
        switch self {
        case .screen: "Screen"
        case .mirror: "Mirror"
        case .extend: "Extend"
        case .window: "Window"
        }
    }
}

/// The extension's picture and stream settings, as its popup shows them.
struct Look: Equatable {
    var brightness = 0.0, contrast = 1.0, saturation = 1.0, warmth = 0.0, gamma = 1.0

    static let styles: [(String, String, Look)] = [
        ("natural", "Natural", Look()),
        ("video", "Video", Look(contrast: 1.02, gamma: 1.08)),
        ("cinema", "Cinema", Look(contrast: 1.05, warmth: 0.2)),
        ("vivid", "Vivid", Look(contrast: 1.08, saturation: 1.25)),
    ]

    func same(_ other: Look) -> Bool {
        abs(brightness - other.brightness) < 0.001 && abs(contrast - other.contrast) < 0.001 && abs(saturation - other.saturation) < 0.001
            && abs(warmth - other.warmth) < 0.001 && abs(gamma - other.gamma) < 0.001
    }

    var wire: [String: Double] { ["brightness": brightness, "contrast": contrast, "saturation": saturation, "warmth": warmth, "gamma": gamma] }

    init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, warmth: Double = 0, gamma: Double = 1) {
        (self.brightness, self.contrast, self.saturation, self.warmth, self.gamma) = (brightness, contrast, saturation, warmth, gamma)
    }

    init(_ wire: [String: Any]?) {
        self.init()
        guard let wire else { return }
        brightness = wire["brightness"] as? Double ?? 0
        contrast = wire["contrast"] as? Double ?? 1
        saturation = wire["saturation"] as? Double ?? 1
        warmth = wire["warmth"] as? Double ?? 0
        gamma = wire["gamma"] as? Double ?? 1
    }
}

/// The Mac app's own settings, as its window last shared them.
struct MacSettings: Equatable {
    struct Choice: Hashable { let value: String, title: String }
    var quality = "better", height = 1440, bitrate = 40, fps = 60, playback = "smooth", udp = false, codec = "hevc", tenBit = true
    var profile = "srgb", volume = 1.0
    var look = Look()
    var resolutions: [Choice] = [], bitrates: [Int] = [], codecs: [String] = [], profiles: [Choice] = []

    init() {}

    init(_ e: [String: Any]) {
        quality = e["quality"] as? String ?? quality
        height = e["height"] as? Int ?? height
        bitrate = e["bitrate"] as? Int ?? bitrate
        fps = e["fps"] as? Int ?? fps
        playback = e["playback"] as? String ?? playback
        udp = e["udp"] as? Bool ?? udp
        codec = e["codec"] as? String ?? codec
        tenBit = e["tenBit"] as? Bool ?? tenBit
        profile = e["profile"] as? String ?? profile
        volume = e["volume"] as? Double ?? volume
        look = Look(e["look"] as? [String: Any])
        resolutions = (e["resolutions"] as? [[String: Any]] ?? []).compactMap { r in
            (r["height"] as? Int).map { Choice(value: String($0), title: r["title"] as? String ?? "\($0)p") }
        }
        bitrates = e["bitrates"] as? [Int] ?? []
        codecs = e["codecs"] as? [String] ?? []
        profiles = (e["profiles"] as? [[String: Any]] ?? []).compactMap { p in
            (p["id"] as? String).map { Choice(value: $0, title: p["title"] as? String ?? $0) }
        }
    }
}

struct CastSettings: Equatable {
    var look = Look()
    var size = "cover"
    var quality = "4k"
    var bitrate = "auto"
    var fps = 60
    var delay = 400
}

/// What's playing: a cast browser tab (through the extension) or a video the TV plays itself.
struct Playback: Equatable {
    var title: String
    var time: Double
    var duration: Double
    var paused: Bool
    var live: Bool
    var volume: Double?
    var direct: Bool
}

/// Finds Throwcast on the network, pairs once, then mirrors the Mac's state and sends commands.
@Observable @MainActor
final class Remote {
    enum Link: Equatable { case searching, connecting, pairing(code: String), enterCode(triesLeft: Int?), refused(String), connected, lost(String) }

    var macs: [Mac] = []
    var tvTargets: [Mac] = []
    var lookingForTVs = false
    var controlsTV: Bool { current?.kind == .tv }
    var link: Link = .searching
    var macName = ""
    var tvs: [TVInfo] = []
    var selectedTV: String?
    var castState = "stopped"
    var failure: String?
    var notice: String?
    var stats: (fps: Double, mbps: Double)?
    var windows: [WindowInfo] = []
    var windowsLoading = false
    var playback: Playback?
    /// The extension's settings, when the phone controls a cast from Chrome through the TV.
    var settings: CastSettings?
    /// The Mac app's settings, when the phone controls the Mac.
    var macSettings: MacSettings?
    private var tabSeen = Date.distantPast

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var current: Mac?
    private var tvPort: UInt16 = 47150
    private var retryUntil = Date.distantPast
    private let queue = DispatchQueue(label: "remote.net")
    private let phoneName = UIDevice.current.name

    var casting: Bool { castState == "casting" || castState == "connecting" }
    var tabCasting: Bool { controlsTV || (Date().timeIntervalSince(tabSeen) < 3 && playback?.direct == false) }

    func browse() {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: "_throwcast._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Mac? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Mac(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in
                guard let self else { return }
                self.macs = found
                // One Mac you've paired with before: go straight to it.
                self.autoConnect()
            }
        }
        browser.start(queue: queue)
        self.browser = browser
        findTVs()
    }

    /// A paired Mac first, then a paired TV that's running Throwcast, then the only one found.
    private func autoConnect() {
        guard current == nil, link == .searching else { return }
        let all = macs + tvTargets
        if let target = macs.first(where: { Self.token(for: $0.id) != nil }) ?? tvTargets.first(where: { Self.token(for: $0.id) != nil })
            ?? (all.count == 1 && !lookingForTVs ? all.first : nil) {
            connect(target)
        }
    }

    /// TVs running the Throwcast app. TV apps can't advertise with Bonjour, so the phone asks Samsung's own
    /// service on port 8001: first at TVs it already knows, then across this network.
    func findTVs() {
        guard !lookingForTVs else { return }
        lookingForTVs = true
        Task {
            let known = UserDefaults.standard.stringArray(forKey: "tvHosts") ?? []
            var found = await TVFinder.find(in: known)
            if found.isEmpty { found = await TVFinder.find(in: TVFinder.neighbours()) }
            tvTargets = found.map { Mac(name: $0.name, endpoint: .hostPort(host: .init($0.host), port: 47150), kind: .tv, host: $0.host) }
            lookingForTVs = false
            autoConnect()
        }
    }

    func addTV(host: String) {
        Task {
            if let tv = await TVFinder.find(in: [host]).first {
                let target = Mac(name: tv.name, endpoint: .hostPort(host: .init(tv.host), port: 47150), kind: .tv, host: tv.host)
                tvTargets.removeAll { $0.host == tv.host }
                tvTargets.append(target)
                connect(target)
            } else {
                notice = "No TV running Throwcast answered at \(host)."
            }
        }
    }

    func connect(_ mac: Mac) {
        connection?.cancel()
        current = mac
        link = .connecting
        if mac.kind == .tv {
            tvPort = 47150
            retryUntil = Date().addingTimeInterval(10)
        }
        open(mac)
    }

    /// A TV takes the first free port of 47150-47159, and its page reloads after every cast, so a TV
    /// connection tries the next port, and quietly tries again for a few seconds, before giving up.
    private func open(_ mac: Mac) {
        connection?.cancel()
        // Apple's WebSocket client only sends its opening request when it's given a ws:// link; with a bare
        // address or a Bonjour name it connects and waits forever. So a Mac's Bonjour name is looked up first.
        if mac.kind == .mac, case .service = mac.endpoint {
            return resolve(mac)
        }
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        let port = mac.kind == .tv ? tvPort : resolvedPort
        let host = (mac.host ?? "").contains(":") ? "[\((mac.host ?? "").split(separator: "%")[0])]" : (mac.host ?? "")
        guard let link = URL(string: "ws://\(host):\(port)") else { return lose("Can't reach \(mac.name).") }
        let endpoint = NWEndpoint.url(link)
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready: self.hello()
                case let .failed(error): self.dropped(mac, "Lost \(mac.name): \(error.localizedDescription)")
                case let .waiting(error): self.dropped(mac, "Can't reach \(mac.name): \(error.localizedDescription)")
                default: break
                }
            }
        }
        self.connection = connection
        connection.start(queue: queue)
        receive(on: connection)
        // A Mac or TV that's gone can leave a connection waiting forever. Five seconds is plenty on a LAN.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection, self.link == .connecting else { return }
            self.dropped(mac, "\(mac.name) didn't answer. Is Throwcast open on it?")
        }
    }

    func disconnect() {
        retryUntil = .distantPast
        connection?.cancel()
        connection = nil
        current = nil
        link = .searching
    }

    /// The code the TV shows.
    func submit(code: String) {
        send(["cmd": "hello", "code": code, "name": phoneName])
    }

    func retry() {
        if let current { connect(current) } else { browse() }
    }

    private var resolvedPort: UInt16 = 47126

    /// The Mac's address behind its Bonjour name: a plain connection that's dropped once it's ready.
    private func resolve(_ mac: Mac) {
        // IPv4: an IPv6 link-local address needs its interface, which a ws:// link can't carry.
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let probe = NWConnection(to: mac.endpoint, using: parameters)
        connection = probe
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak probe] in
            guard let self, let probe, self.connection === probe, self.link == .connecting else { return }
            probe.cancel()
            self.lose("\(mac.name) didn't answer. Is Throwcast open on it, and is Local Network on for Throwcast Remote in Settings?")
        }
        probe.stateUpdateHandler = { [weak self, weak probe] state in
            Task { @MainActor in
                guard let self, let probe, self.connection === probe else { return }
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = probe.currentPath?.remoteEndpoint {
                        var address = "\(host)"
                        if case let .ipv4(v4) = host { address = "\(v4)" }
                        probe.cancel()
                        self.resolvedPort = port.rawValue
                        var found = mac
                        found.host = address.split(separator: "%").first.map(String.init) ?? address
                        found.endpoint = .hostPort(host: host, port: port)
                        self.current = found
                        self.open(found)
                    } else {
                        probe.cancel()
                        self.lose("Can't find \(mac.name)'s address.")
                    }
                case let .failed(error), let .waiting(error):
                    probe.cancel()
                    self.lose("Can't reach \(mac.name): \(error.localizedDescription)")
                default: break
                }
            }
        }
        probe.start(queue: queue)
    }

    private func lose(_ reason: String) {
        link = .lost(reason)
    }

    private func dropped(_ mac: Mac, _ reason: String) {
        // Once connected, a drop gets 15 seconds to come back: the TV reloads after every cast and setting change.
        if retryUntil == .distantFuture { retryUntil = Date().addingTimeInterval(15) }
        guard mac.kind == .tv, Date() < retryUntil else { return lose(reason) }
        tvPort = tvPort >= 47159 ? 47150 : tvPort + 1
        if link == .connected { castState = "stopped"; playback = nil; stats = nil }
        let delay = tvPort == 47150 ? 0.8 : 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.current == mac else { return }
            self.open(mac)
        }
    }

    private func hello() {
        guard let mac = current else { return }
        if let token = Self.token(for: mac.id) {
            send(["cmd": "hello", "token": token, "name": phoneName])
        } else {
            pair()
        }
    }

    private func pair() {
        if current?.kind == .tv { return send(["cmd": "hello", "name": phoneName]) }
        let code = String(format: "%06d", Int.random(in: 0 ... 999_999))
        link = .pairing(code: code)
        send(["cmd": "hello", "code": code, "name": phoneName])
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard error == nil else { return }
            if let data, let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Task { @MainActor in self?.apply(event) }
            }
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                self.receive(on: connection)
            }
        }
    }

    func apply(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "needsPairing":
            if let mac = current { Self.forget(mac.id) }
            if event["enterCode"] as? Bool == true {
                // A TV: it shows the code, this phone types it.
                if case .enterCode = link {} else { link = .enterCode(triesLeft: nil) }
            } else if case .pairing = link {} else { pair() }
        case "pairingRefused":
            if let left = event["triesLeft"] as? Int, left > 0 {
                link = .enterCode(triesLeft: left)
            } else if let wait = event["wait"] as? Int {
                link = .refused("Too many wrong codes. Try again in \(wait) seconds.")
            } else {
                link = .refused(controlsTV ? "The TV didn't accept the code." : "The Mac didn't allow this iPhone.")
            }
        case "paired":
            if let mac = current, let token = event["token"] as? String { Self.save(token, for: mac.id) }
        case "welcome":
            retryUntil = .distantFuture
            if tvTargets.isEmpty { findTVs() }
            macName = event["mac"] as? String ?? current?.name ?? "Mac"
            if !controlsTV, settings == nil { settings = CastSettings() }
            link = .connected
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "tv":
            guard let host = event["host"] as? String else { return }
            let tv = TVInfo(host: host, name: event["name"] as? String ?? "TV", width: event["width"] as? Int ?? 3840, height: event["height"] as? Int ?? 2160)
            tvs.removeAll { $0.host == host }
            tvs.append(tv)
            if selectedTV == nil { selectedTV = host }
            // Remembered, so the phone can find this TV when only the browser extension is casting.
            if current?.kind == .mac {
                var hosts = UserDefaults.standard.stringArray(forKey: "tvHosts") ?? []
                if !hosts.contains(host) { hosts.append(host); UserDefaults.standard.set(Array(hosts.suffix(8)), forKey: "tvHosts") }
            }
        case "macSettings":
            // The Mac sends these only when something changes, so each one is the truth: never skipped.
            macSettings = MacSettings(event)
        case "look":
            // The Mac cast's picture. Only the picture: the Mac app keeps its own stream settings.
            if !controlsTV {
                var mac = settings ?? CastSettings()
                mac.look = Look(event)
                settings = mac
            }
        case "remoteStatus":
            if let host = event["selectedTV"] as? String { selectedTV = host }
            if let message = event["message"] as? String { notice = message }
        case "state":
            castState = event["state"] as? String ?? "stopped"
            failure = castState == "failed" ? event["message"] as? String : nil
            if !casting { stats = nil; if playback?.direct == false { playback = nil } }
        case "stats":
            stats = (event["fps"] as? Double ?? 0, event["mbps"] as? Double ?? 0)
        case "windows":
            windowsLoading = false
            windows = (event["windows"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? Int else { return nil }
                let icon = (item["icon"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
                return WindowInfo(id: id, app: item["app"] as? String ?? "App", title: item["title"] as? String ?? "", hidden: item["hidden"] as? Bool ?? false, icon: icon)
            }
        case "tabState":
            tabSeen = Date()
            let title = event["title"] as? String ?? playback?.title ?? "This tab"
            playback = Playback(title: title, time: event["time"] as? Double ?? 0, duration: event["duration"] as? Double ?? 0,
                                paused: event["paused"] as? Bool ?? false, live: event["live"] as? Bool ?? false,
                                volume: event["volume"] as? Double, direct: false)
            if let wire = event["settings"] as? [String: Any], Date() > settingsHeldUntil {
                settings = CastSettings(look: Look(wire["look"] as? [String: Any]), size: wire["size"] as? String ?? "cover",
                                        quality: wire["quality"] as? String ?? "4k", bitrate: "\(wire["bitrate"] ?? "auto")",
                                        fps: wire["fps"] as? Int ?? 60, delay: wire["delay"] as? Int ?? 400)
            }
        case "direct":
            let state = event["state"] as? String ?? "stopped"
            if state == "stopped" || state == "ended" {
                if playback?.direct == true { playback = nil }
                return
            }
            playback = Playback(title: event["title"] as? String ?? playback?.title ?? "Video", time: event["time"] as? Double ?? 0,
                                duration: event["duration"] as? Double ?? 0, paused: state == "paused", live: false, volume: nil, direct: true)
        default: break
        }
    }

    // MARK: Commands

    func start(_ source: Source, window: Int? = nil) {
        var message: [String: Any] = ["cmd": "start", "source": source.rawValue]
        if let selectedTV { message["host"] = selectedTV }
        if let window { message["window"] = window }
        failure = nil
        castState = "connecting"
        send(message)
    }

    func stop() {
        if controlsTV {
            send(["cmd": "endTab"])
        } else if playback?.direct == true {
            send(["cmd": "control", "action": "stop"])
        } else {
            send(["cmd": tabCasting ? "endTab" : "stop"])
        }
    }

    func selectTV(_ host: String) {
        selectedTV = host
        send(["cmd": "selectTV", "host": host])
    }

    func refreshWindows() {
        windowsLoading = true
        send(["cmd": "windows"])
    }

    func rescan() { send(["cmd": "rescan"]) }

    func togglePlay() {
        guard var now = playback else { return }
        let action = now.paused ? "play" : "pause"
        now.paused.toggle()
        playback = now
        playbackCommand(["action": action])
    }

    func jump(_ seconds: Double) { playbackCommand(["action": "jump", "seconds": seconds]) }

    func next() { send(["cmd": "tabControl", "action": "next"]) }
    func previous() { send(["cmd": "tabControl", "action": "previous"]) }
    func goLive() { send(["cmd": "tabControl", "action": "live"]) }

    /// A change made here wins over the TV's next report for a moment, so a slider doesn't jump back.
    private var settingsHeldUntil = Date.distantPast

    func setLook(_ look: Look) {
        settings?.look = look
        settingsHeldUntil = Date().addingTimeInterval(1.5)
        if controlsTV {
            send(["cmd": "look", "look": look.wire])
        } else {
            macSettings?.look = look
            setMac("look", look.wire)
        }
    }

    func setSize(_ size: String) {
        settings?.size = size
        settingsHeldUntil = Date().addingTimeInterval(1.5)
        send(["cmd": "size", "size": size])
    }

    /// One of the Mac app's settings, applied by its window as if clicked there. A running cast restarts if it has to.
    func setMac(_ name: String, _ value: Any) {
        // Shown at once; the Mac's reply, a moment later, confirms it or puts it right.
        if var mac = macSettings {
            switch name {
            case "quality": mac.quality = value as? String ?? mac.quality
            case "height": mac.height = value as? Int ?? mac.height
            case "bitrate": mac.bitrate = value as? Int ?? mac.bitrate
            case "fps": mac.fps = value as? Int ?? mac.fps
            case "playback": mac.playback = value as? String ?? mac.playback
            case "udp": mac.udp = value as? Bool ?? mac.udp
            case "codec": mac.codec = value as? String ?? mac.codec
            case "tenBit": mac.tenBit = value as? Bool ?? mac.tenBit
            case "profile": mac.profile = value as? String ?? mac.profile
            case "volume": mac.volume = value as? Double ?? mac.volume
            default: break
            }
            macSettings = mac
        }
        send(["cmd": "appSetting", "name": name, "value": value])
    }

    /// Quality, bitrate, frame rate or delay. The stream starts again, so the TV reloads and the phone reconnects.
    func setStream(_ name: String, _ value: Any) {
        switch name {
        case "quality": settings?.quality = value as? String ?? "4k"
        case "bitrate": settings?.bitrate = "\(value)"
        case "fps": settings?.fps = value as? Int ?? 60
        case "delay": settings?.delay = value as? Int ?? 400
        default: break
        }
        settingsHeldUntil = Date().addingTimeInterval(4)
        send(["cmd": "stream", "changes": [name: value]])
    }

    func seek(to seconds: Double) {
        playback?.time = seconds
        playbackCommand(["action": "seek", "seconds": seconds])
    }

    func setVolume(_ value: Double) {
        playback?.volume = value
        if tabCasting {
            send(["cmd": "tabControl", "volume": value])
        } else {
            // Through the Mac app's window, so its slider moves too.
            macSettings?.volume = value
            setMac("volume", value)
        }
    }

    private func playbackCommand(_ command: [String: Any]) {
        let cmd = playback?.direct == true ? "control" : "tabControl"
        send(command.merging(["cmd": cmd]) { a, _ in a })
    }

    private func send(_ object: [String: Any]) {
        guard let connection, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let context = NWConnection.ContentContext(identifier: "remote", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    // MARK: Pairing tokens, one per Mac, in the Keychain.

    private static func token(for mac: String) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Throwcast Remote",
                                    kSecAttrAccount as String: mac, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func save(_ token: String, for mac: String) {
        forget(mac)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Throwcast Remote",
                                   kSecAttrAccount as String: mac, kSecValueData as String: Data(token.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func forget(_ mac: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Throwcast Remote", kSecAttrAccount as String: mac]
        SecItemDelete(query as CFDictionary)
    }
}
