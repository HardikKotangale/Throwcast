import AppKit
import CoreGraphics
import Foundation
import Network
import ScreenCaptureKit

/// Everything the window asks for, on the main queue. Lives in the app's own process so macOS
/// has one identity to grant Screen Recording and Local Network to.
public final class Engine {
    public var emitLine: ((String) -> Void)?
    private var session: CastSession?
    private var browser: NWBrowser?
    private var connectionTest: ConnectionTest?
    private var direct: DirectPlayback?
    private let control = LocalControl()
    private let tabAudio = TabAudioServer()
    private var selected: TV?
    private var lastFailure: String?
    /// The TV's latest report, so the extension and tools can show real numbers.
    private var lastStats: [String: Any]?
    private var tabDisplay: VirtualDisplay?
    /// Controls from the app wait here for the extension's next check-in, about twice a second.
    private var tabCommands: [[String: Any]] = []
    private var lastTabCheckIn = Date.distantPast
    /// The level asked for, which stays in charge even if the site won't go along with it.
    private var tabVolume: Double?
    private var tabVolumeSent = Date.distantPast

    public init() {}

    public func receive(_ line: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        DispatchQueue.main.async { self.handle(message) }
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        emitLine?(String(decoding: data, as: UTF8.self))
    }

    private func handle(_ message: [String: Any]) {
        switch message["cmd"] as? String {
        case "hello":
            emit(["event": "permission", "screen": CGPreflightScreenCaptureAccess()])
            emit(["event": "encoders", "codecs": VideoCodec.available.map(\.rawValue)])
            discover()
            startControl()
        case "checkPermission":
            emit(["event": "permission", "screen": CGPreflightScreenCaptureAccess()])
        case "requestPermission":
            _ = CGRequestScreenCaptureAccess()
        case "addTV":
            if let host = message["host"] as? String { add(host, reportFailure: true) }
        case "adjust":
            session?.setAdjustments(Self.adjustments(message))
        case "selectTV":
            if let host = message["host"] as? String { Task { @MainActor in self.selected = await TV.fetch(host: host) } }
        case "stopDirect":
            stopDirect()
        case "tabControl":
            if message["volume"] != nil { setTabVolume(Self.volume(message)) } else { tabCommands.append(message) }
        case "volume":
            session?.setVolume(Self.volume(message))
        case "endTab":
            endTabThroughExtension()
        case "rescan":
            scan()
        case "testConnection":
            if let host = message["host"] as? String { testConnection(host) }
        case "windows":
            sendWindows()
        case "screen":
            sendScreen()
        case "start":
            start(message)
        case "stop":
            session?.stop()
        default: break
        }
    }

    private func startControl() {
        control.handler = { [weak self] request, respond in self?.answer(request, respond) }
        try? control.start()
        tabAudio.onAudio = { [weak self] pcm in self?.session?.sendTabAudio(pcm) }
        try? tabAudio.start()
    }

    /// Requests from the browser extension.
    private func answer(_ request: ControlRequest, _ respond: @escaping (Int, [String: Any]) -> Void) {
        switch (request.method, request.path) {
        case ("GET", "/status"):
            var status: [String: Any] = ["casting": session != nil]
            if let lastFailure { status["failure"] = lastFailure }
            if let tabVolume { status["tabVolume"] = tabVolume }
            if session != nil, let lastStats { status["stats"] = lastStats }
            if let selected { status["tv"] = ["name": selected.name, "resolution": selected.resolutionLabel] }
            if let direct {
                let now = direct.status
                status["playback"] = ["title": direct.title, "state": now.state, "time": now.time, "duration": now.duration, "error": now.error as Any]
            }
            respond(200, status)
        case ("POST", "/play"):
            play(request.body, respond)
        case ("POST", "/castTab"):
            castTab(request.body, respond)
        case ("POST", "/tabState"):
            lastTabCheckIn = Date()
            let reported = request.body["volume"] as? Double ?? 1
            // The page gets a moment to apply a change, or the two would briefly stack.
            if let tabVolume, Date().timeIntervalSince(tabVolumeSent) > 1 { session?.setVolume(Self.gain(wanted: tabVolume, reported: reported)) }
            emit(["event": "tabState", "time": request.body["time"] as? Double ?? 0, "duration": request.body["duration"] as? Double ?? 0,
                  "paused": request.body["paused"] as? Bool ?? false, "size": request.body["size"] as? String ?? "cover",
                  "volume": tabVolume ?? reported,
                  "live": request.body["live"] as? Bool ?? false, "behind": request.body["behind"] as? Double ?? 0,
                  "start": request.body["start"] as? Double ?? -1])
            respond(200, ["commands": tabCommands])
            tabCommands = []
        case ("POST", "/tabVolume"):
            setTabVolume(Self.volume(request.body))
            respond(200, [:])
        case ("POST", "/castTab/begin"):
            beginTab(respond)
        case ("POST", "/control"):
            guard let action = request.body["action"] as? String, ["play", "pause", "seek", "jump"].contains(action) else {
                if request.body["action"] as? String == "stop" {
                    stopDirect()
                    endTab()
                }
                return respond(200, [:])
            }
            direct?.control(action, seconds: request.body["seconds"] as? Double)
            respond(200, [:])
        default:
            respond(404, ["error": "Not found"])
        }
    }

    private func play(_ body: [String: Any], _ respond: @escaping (Int, [String: Any]) -> Void) {
        guard let tv = selected else { return respond(409, ["error": "Choose a TV in Throwcast first."]) }
        let start = max(0, body["start"] as? Double ?? 0)
        let title = String((body["title"] as? String ?? "Video").prefix(200))
        session?.stop()
        stopDirect()
        let sources = ([body] + (body["alternates"] as? [[String: Any]] ?? [])).prefix(5)
        guard let relay = StreamRelay(allowedHost: tv.host) else { return respond(500, ["error": "This Mac isn't on a network."]) }
        let links = sources.compactMap { source -> String? in
            guard let link = source["url"] as? String, link.count < 8192, let url = URL(string: link),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return relay.register(url: link, headers: source["headers"] as? [String: String] ?? [:])
        }
        guard !links.isEmpty else { return respond(400, ["error": "That video link can't be sent to a TV."]) }
        let playback = DirectPlayback(host: tv.host, links: links, title: title, start: start, relay: relay)
        playback.onChange = { [weak self] status in
            DispatchQueue.main.async {
                guard self?.direct === playback else { return }
                self?.emit(["event": "direct", "title": title, "state": status.state, "time": status.time, "duration": status.duration, "error": status.error as Any])
            }
        }
        // The port frees a moment after a cast or earlier video ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            do {
                try playback.begin()
                self?.direct = playback
                self?.emit(["event": "direct", "title": title, "state": "starting", "time": 0.0, "duration": 0.0])
                Task {
                    let launched = await tv.launchReceiver()
                    launched ? respond(200, ["app": "Throwcast"]) : respond(502, ["error": CastError.receiverMissing.localizedDescription])
                }
            } catch {
                respond(500, ["error": error.localizedDescription])
            }
        }
    }

    private static func rect(_ values: [String: Any]?) -> CGRect? {
        guard let values, let x = values["x"] as? Double, let y = values["y"] as? Double,
              let width = values["width"] as? Double, let height = values["height"] as? Double,
              width >= 100, height >= 100 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Makes a private display for a browser tab. It's always on screen, so the browser keeps drawing
    /// while the user works elsewhere, and macOS removes it if the app ever quits or crashes.
    private func beginTab(_ respond: @escaping (Int, [String: Any]) -> Void) {
        guard let tv = selected else { return respond(409, ["error": "Choose a TV in Throwcast first."]) }
        session?.stop()
        stopDirect()
        lastFailure = nil
        tabVolume = nil
        tabCommands = []
        // Extra height holds the menu bar and title bar, which the crop then leaves out.
        if tabDisplay == nil {
            tabDisplay = VirtualDisplay(width: tv.width, height: tv.height + 240, fps: 60, name: "Throwcast TV")
        }
        guard let display = tabDisplay else { return respond(500, ["error": CastError.virtualDisplayFailed.localizedDescription]) }
        Task { @MainActor in
            for _ in 0 ..< 30 {
                let bounds = CGDisplayBounds(display.id)
                if bounds.width > 0, Self.isOnline(display.id) {
                    return respond(200, ["x": Double(bounds.minX), "y": Double(bounds.minY), "width": Double(bounds.width), "height": Double(bounds.height)])
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            respond(500, ["error": CastError.virtualDisplayFailed.localizedDescription])
        }
    }

    private static func isOnline(_ id: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.contains(id)
    }

    /// A live tab goes home through the extension. If it's gone quiet, end here so nothing gets stuck.
    private func endTabThroughExtension() {
        if Date().timeIntervalSince(lastTabCheckIn) < 3 {
            tabCommands.append(["stop": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.endTab() }
        } else {
            endTab()
        }
    }

    private func endTab() {
        session?.stop()
        // A moment for the browser to take the tab back before the display disappears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if self?.session == nil { self?.tabDisplay = nil }
        }
    }

    /// Finds the browser window by its exact position, then lets the app start a normal cast of it,
    /// so the user's resolution, color and bitrate settings all apply.
    private func castTab(_ body: [String: Any], _ respond: @escaping (Int, [String: Any]) -> Void) {
        guard selected != nil else { return respond(409, ["error": "Choose a TV in Throwcast first."]) }
        guard let bounds = Self.rect(body["bounds"] as? [String: Any]), let crop = Self.rect(body["crop"] as? [String: Any]) else {
            return respond(400, ["error": "Couldn't read this browser window."])
        }
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
                return respond(500, ["error": "Throwcast needs Screen Recording access."])
            }
            let browsers = content.windows.filter { $0.windowLayer == 0 && $0.frame.width >= 200 && Self.browserApps.contains($0.owningApplication?.bundleIdentifier ?? "") }
            func distance(_ window: SCWindow) -> CGFloat {
                abs(window.frame.minX - bounds.minX) + abs(window.frame.minY - bounds.minY) + abs(window.frame.width - bounds.width) + abs(window.frame.height - bounds.height)
            }
            // Browser windows are often stacked at the same size, so the tab's title decides first.
            let title = body["title"] as? String ?? ""
            let matches = browsers.filter { !title.isEmpty && ($0.title ?? "").contains(title) }
            guard let window = (matches.isEmpty ? browsers : matches).min(by: { distance($0) < distance($1) }), distance(window) < 80 else {
                return respond(404, ["error": "Couldn't find this browser window. Move it onto your screen and try again."])
            }
            stopDirect()
            emit(["event": "castTab", "window": Int(window.windowID), "crop": ["x": Double(crop.minX), "y": Double(crop.minY), "width": Double(crop.width), "height": Double(crop.height)],
                  "title": String((body["title"] as? String ?? "Browser tab").prefix(200))])
            respond(200, [:])
        }
    }

    private static let browserApps: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "org.chromium.Chromium"]

    private func stopDirect() {
        guard let direct else { return }
        direct.stop()
        self.direct = nil
        emit(["event": "direct", "state": "stopped"])
    }

    /// A dragged slider sends many values, and only the newest matters.
    private func setTabVolume(_ value: Double) {
        tabVolume = value
        tabVolumeSent = Date()
        tabCommands.removeAll { $0["volume"] != nil }
        tabCommands.append(["volume": value])
    }

    /// When a site ignores the volume it's given, the TV's audio is lowered here instead.
    static func gain(wanted: Double, reported: Double) -> Double {
        reported > wanted ? wanted / reported : 1
    }

    private static func volume(_ message: [String: Any]) -> Double {
        min(1, max(0, message["volume"] as? Double ?? 1))
    }

    private static func adjustments(_ message: [String: Any]) -> Adjustments {
        Adjustments(brightness: message["brightness"] as? Double ?? 0, contrast: message["contrast"] as? Double ?? 1,
                    saturation: message["saturation"] as? Double ?? 1, warmth: message["warmth"] as? Double ?? 0,
                    gamma: message["gamma"] as? Double ?? 1)
    }

    private func discover() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_samsungmsf._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in results.forEach { self?.resolve($0.endpoint) } }
        browser.start(queue: .main)
        self.browser = browser
        scan()
    }

    private func scan() {
        Task {
            let tvs = await TV.scanLocalNetwork()
            await MainActor.run {
                tvs.forEach(self.send)
                // Keep looking in case the TV was off or just joining the network.
                if tvs.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.scan() } }
            }
        }
    }

    private func send(_ tv: TV) {
        emit(["event": "tv", "id": tv.id, "name": tv.name, "model": tv.model, "host": tv.host, "width": tv.width, "height": tv.height])
    }

    /// Bonjour gives a service name; connecting briefly reveals the address the TV's API lives at.
    private func resolve(_ endpoint: NWEndpoint) {
        // IPv4 only: a link-local IPv6 answer can't be used to reach the TV's API.
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint else { return }
            connection.cancel()
            self?.add(String("\(host)".split(separator: "%")[0]), reportFailure: false)
        }
        connection.start(queue: .main)
    }

    private func add(_ host: String, reportFailure: Bool) {
        Task {
            guard let tv = await TV.fetch(host: host) else {
                if reportFailure { emit(["event": "addFailed", "host": host]) }
                return
            }
            send(tv)
        }
    }

    private func sendWindows() {
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            // Regular apps only: this drops system helpers and invisible overlays.
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            let candidates: [(SCWindow, NSRunningApplication)] = content.windows.compactMap { window in
                guard window.windowLayer == 0, window.title?.isEmpty == false, window.frame.width >= 160, window.frame.height >= 120,
                      let pid = window.owningApplication?.processID, pid != ProcessInfo.processInfo.processIdentifier,
                      let app = apps.first(where: { $0.processIdentifier == pid }) else { return nil }
                return (window, app)
            }
            let previews = await withTaskGroup(of: (Int, [String: Any]?).self) { group in
                for (index, pair) in candidates.prefix(16).enumerated() {
                    group.addTask { (index, await Self.preview(pair.0, app: pair.1)) }
                }
                var found: [(Int, [String: Any])] = []
                for await (index, item) in group { if let item { found.append((index, item)) } }
                return found.sorted { $0.0 < $1.0 }.map(\.1)
            }
            emit(["event": "windows", "windows": previews])
        }
    }

    private func sendScreen() {
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return }
            let settings = SCStreamConfiguration()
            settings.width = 640
            settings.height = max(640 * display.height / max(display.width, 1), 1)
            settings.showsCursor = false
            let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: settings),
                  let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
            emit(["event": "screen", "image": jpeg.base64EncodedString(), "aspect": Double(display.width) / Double(max(display.height, 1))])
        }
    }

    /// A small live picture of the window. Nil means macOS can't capture it, such as when minimized.
    private static func preview(_ window: SCWindow, app: NSRunningApplication) async -> [String: Any]? {
        let settings = SCStreamConfiguration()
        let aspect = window.frame.height / max(window.frame.width, 1)
        settings.width = 560
        settings.height = max(Int(560 * aspect), 1)
        settings.ignoreShadowsSingleWindow = true
        settings.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: settings),
              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        var item: [String: Any] = ["id": Int(window.windowID), "app": app.localizedName ?? "App", "title": window.title ?? "",
                                   "image": jpeg.base64EncodedString(), "aspect": window.frame.width / max(window.frame.height, 1)]
        if let png = smallIcon(app.icon) { item["icon"] = png.base64EncodedString() }
        return item
    }

    /// App icons come at up to 1024 pixels, and the tile only needs enough for Retina at 18 points.
    private static func smallIcon(_ icon: NSImage?) -> Data? {
        var rect = CGRect(x: 0, y: 0, width: 36, height: 36)
        guard let image = icon?.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 36, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 36, height: 36))
        return context.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    private func start(_ message: [String: Any]) {
        guard session == nil, let host = message["host"] as? String else { return }
        stopDirect()
        lastFailure = nil
        var config = StreamConfig(width: message["width"] as? Int ?? 3840, height: message["height"] as? Int ?? 2160)
        let fps = message["fps"] as? Int ?? 60
        config.fps = [24, 30, 60, 120].contains(fps) ? fps : 60
        config.bitrateMbps = message["bitrateMbps"] as? Int
        config.color = (message["color"] as? String).flatMap(ColorMode.init) ?? .srgb
        config.quality = (message["quality"] as? String).flatMap(Quality.init) ?? .better
        config.tenBit = message["tenBit"] as? Bool ?? true
        config.hdrPeakNits = message["hdrPeakNits"] as? Int ?? 1000
        // Only an encoder this Mac really has; H.264 can't carry HDR, so it gets standard video color.
        // Another Mac may lack the saved one; then whatever this Mac does have, HEVC first.
        let available = VideoCodec.available
        let wanted = (message["codec"] as? String).flatMap(VideoCodec.init)
        config.codec = wanted.flatMap { available.contains($0) ? $0 : nil } ?? available.first ?? .hevc
        if config.codec == .h264, config.color == .hdr { config.color = .accurate }
        config.delayMs = message["delayMs"] as? Int ?? ((message["smooth"] as? Bool ?? true) ? 400 : 33)
        config.udp = message["transport"] as? String == "udp"
        config.adjustments = Self.adjustments(message)
        config.volume = Self.volume(message)
        // A tab whose sound comes straight from the browser: recording all of Chrome would add other tabs.
        config.capturesAudio = !(tabDisplay != nil && tabAudio.isConnected)
        let source: CastSource = switch message["source"] as? String {
        case "mirror": .mirror
        case "extend": .extend
        case "window": .window(CGWindowID(message["window"] as? Int ?? 0), crop: Self.rect(message["crop"] as? [String: Any]))
        default: .screen
        }
        let session = CastSession(host: host, config: config, source: source)
        session.onState = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .connecting: self.emit(["event": "state", "state": "connecting"])
                case .casting:
                    self.emit(["event": "state", "state": "casting"])
                case .stopped:
                    self.session = nil
                    self.emit(["event": "state", "state": "stopped"])
                case let .failed(reason):
                    self.session = nil
                    self.emit(["event": "state", "state": "failed", "message": reason])
                    self.lastFailure = reason
                }
            }
        }
        session.onCaptureEnded = { [weak self] in
            DispatchQueue.main.async {
                if self?.tabDisplay != nil { self?.endTabThroughExtension() }
            }
        }
        session.onPreview = { [weak self] jpeg in
            self?.emit(["event": "tvFrame", "image": jpeg.base64EncodedString()])
        }
        session.onStats = { [weak self] stats in
            let report: [String: Any] = ["lost": stats.lost, "fps": stats.fps, "mbps": stats.mbps, "rttMs": stats.rttMs, "dropped": stats.dropped, "bitrateMbps": stats.bitrateMbps,
                                         "encodedFps": stats.encodedFps, "width": config.width, "height": config.height]
            DispatchQueue.main.async { self?.lastStats = report }
            self?.emit(["event": "stats"].merging(report) { a, _ in a })
        }
        self.session = session
        session.start()
        Task { [weak self] in
            if await TV(host: host)?.launchReceiver() == false {
                await MainActor.run { self?.session?.fail(CastError.receiverMissing.localizedDescription) }
            }
        }
    }

    private func testConnection(_ host: String) {
        guard session == nil, connectionTest == nil else { return }
        emit(["event": "test", "state": "running"])
        Task { [weak self] in
            guard let tv = await TV.fetch(host: host), await tv.launchReceiver() else {
                await MainActor.run {
                    self?.emit(["event": "test", "state": "failed", "message": CastError.receiverMissing.localizedDescription])
                }
                return
            }
            await MainActor.run {
                let test = ConnectionTest(host: host) { [weak self] result in
                    DispatchQueue.main.async {
                        self?.connectionTest = nil
                        switch result {
                        case let .success(value):
                            self?.emit(["event": "test", "state": "done", "rttMs": value.rttMs, "mbps": value.mbps, "recommended": value.recommendedMbps])
                        case let .failure(error):
                            self?.emit(["event": "test", "state": "failed", "message": error.localizedDescription])
                        }
                    }
                }
                self?.connectionTest = test
                test.start()
            }
        }
    }
}

private extension TV {
    init?(host: String) async {
        guard let tv = await TV.fetch(host: host) else { return nil }
        self = tv
    }
}
