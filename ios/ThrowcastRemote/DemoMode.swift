#if DEBUG
import Foundation
import Network

/// Screens for the README, without a Mac or TV: `-demo <screen>` at launch fills the remote with a
/// realistic cast. Debug builds only.
extension Remote {
    static var demoScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: "-demo"), at + 1 < args.count else { return nil }
        return args[at + 1]
    }

    func demo(_ screen: String) {
        let mac = Mac(name: "Hardik’s MacBook Pro", endpoint: .hostPort(host: "10.0.0.224", port: 47126))
        let tv = Mac(name: "Samsung AU8000 55 TV", endpoint: .hostPort(host: "10.0.0.220", port: 47150), kind: .tv, host: "10.0.0.220")
        macs = [mac]
        tvTargets = [tv]
        macName = mac.name
        tvs = [TVInfo(host: "10.0.0.220", name: "Samsung AU8000 55 TV", width: 3840, height: 2160)]
        selectedTV = "10.0.0.220"
        var settings = MacSettings()
        settings.quality = "best"; settings.height = 2160; settings.bitrate = 60; settings.fps = 60
        settings.playback = "smooth"; settings.codec = "hevc"; settings.codecs = ["hevc", "h264"]
        settings.resolutions = [.init(value: "1080", title: "Full HD"), .init(value: "1440", title: "2K"), .init(value: "2160", title: "4K")]
        settings.bitrates = [10, 20, 40, 60, 80]
        settings.profiles = [.init(value: "srgb", title: "Natural"), .init(value: "video", title: "Video"), .init(value: "cinema", title: "Cinema")]
        settings.profile = "cinema"; settings.volume = 0.8
        settings.look = Look(contrast: 1.05, warmth: 0.2)
        macSettings = settings
        switch screen {
        case "connect":
            link = .searching
        case "pair":
            link = .pairing(code: "482913")
        case "tvcode":
            link = .enterCode(triesLeft: nil)
        case "playing":
            link = .connected
            castState = "casting"
            stats = (59.6, 38)
            playback = Playback(title: "Big Buck Bunny · 4K", time: 312, duration: 596, paused: false, live: false, volume: 0.8, direct: false)
        default:   // "stream", "picture": the Mac app's settings during a screen cast
            link = .connected
            castState = "casting"
            stats = (59.8, 41)
        }
    }
}
#endif
