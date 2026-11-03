import AppKit
import Foundation
import ThrowcastCore

// Developer tool: `--cast <tv-ip> [--seconds N] [--source screen|mirror|extend] [--color accurate|hdr] [--fps 30|60] [--quality good|better|best]` runs without a UI.
if let index = CommandLine.arguments.firstIndex(of: "--cast"), index + 1 < CommandLine.arguments.count {
    runHeadless(host: CommandLine.arguments[index + 1])
} else if CommandLine.arguments.contains("--windows") {
    _ = NSApplication.shared
    let engine = Engine()
    let start = Date()
    engine.emitLine = { line in
        guard line.contains("windows") else { return }
        let root = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let list = root["windows"] as! [[String: Any]]
        print(String(format: "%.1fs", Date().timeIntervalSince(start)), list.count, "windows", line.count / 1024, "KB")
        for item in list { print(" ", item["app"]!, "-", item["title"]!, (item["image"] as! String).count / 1024, "KB") }
        exit(0)
    }
    engine.receive(#"{"cmd":"windows"}"#)
    dispatchMain()
} else if CommandLine.arguments.contains("--find") {
    Task {
        let start = Date()
        let tvs = await TV.scanLocalNetwork()
        print(tvs.map { "\($0.name) \($0.host) \($0.width)x\($0.height)" }, String(format: "%.1fs", Date().timeIntervalSince(start)))
        exit(0)
    }
    dispatchMain()
} else {
    print("Usage: Throwcast --cast <tv-ip> | --find")
}

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: "--\(name)"), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func runHeadless(host: String) {
    Task {
        guard let tv = await TV.fetch(host: host) else {
            print("No Samsung TV answered at \(host)")
            exit(1)
        }
        var config = StreamConfig(width: tv.width, height: tv.height)
        config.fps = option("fps").flatMap(Int.init) ?? 60
        config.color = option("color").flatMap(ColorMode.init) ?? .accurate
        config.quality = option("quality").flatMap(Quality.init) ?? .better
        config.delayMs = ["smooth": 400, "balanced": 100, "instant": 33, "low": 33][option("playback") ?? "smooth"] ?? 400
        config.udp = option("transport") == "udp"
        config.codec = option("codec").flatMap(VideoCodec.init) ?? .hevc
        config.bitrateMbps = option("bitrate").flatMap(Int.init)
        let source: CastSource = switch option("source") {
        case "mirror": .mirror
        case "extend": .extend
        default: .screen
        }
        print("Casting to \(tv.name) \(config.width)x\(config.height)@\(config.fps) \(config.color.rawValue) \(config.bitrate / 1_000_000) Mbps")
        let session = CastSession(host: host, config: config, source: source)
        session.onState = { state in
            print("state:", state)
            switch state {
            case .stopped: exit(0)
            case .failed: exit(1)
            default: break
            }
        }
        session.onStats = { print(String(format: "tv %.0f fps  captured %.0f  encoded %.0f  %.1f Mbps  target %.0f  rtt %.0f ms  gap %.0f ms  dropped %d  lost %d", $0.fps, $0.capturedFps, $0.encodedFps, $0.mbps, $0.bitrateMbps, $0.rttMs, $0.maxGapMs, $0.dropped, $0.lost) + ($0.udpReport.isEmpty ? "" : "  udp[\($0.udpReport)]")) }
        session.start()
        print("launch:", await tv.launchReceiver())
        try await Task.sleep(for: .seconds(option("seconds").flatMap(Double.init) ?? 20))
        session.stop()
    }
    dispatchMain()
}
