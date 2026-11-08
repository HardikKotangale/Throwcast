import SwiftUI

@main
struct ThrowcastRemoteApp: App {
    @State private var remote = Remote()

    var body: some Scene {
        WindowGroup {
            Root().environment(remote).onAppear {
                #if DEBUG
                if let screen = Remote.demoScreen { return remote.demo(screen) }
                #endif
                remote.browse()
            }
        }
    }
}

struct Root: View {
    @Environment(Remote.self) private var remote

    var body: some View {
        NavigationStack {
            Group {
                if remote.link == .connected { RemoteScreen() } else { ConnectScreen() }
            }
            .background(Color(.systemGroupedBackground))
        }
    }
}

// MARK: Connect and pair

struct ConnectScreen: View {
    @Environment(Remote.self) private var remote

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch remote.link {
                case let .pairing(code):
                    pairing(code)
                case let .enterCode(triesLeft):
                    CodeEntry(triesLeft: triesLeft)
                case let .refused(reason):
                    message(reason, action: "Try Again") { remote.retry() }
                case let .lost(reason):
                    message(reason, action: "Reconnect") { remote.retry() }
                case .connecting:
                    ProgressView("Connecting…").padding(.top, 40)
                default:
                    macList
                }
            }
            .padding(16)
        }
        .navigationTitle("Throwcast")
    }

    @State private var address = ""

    private var macList: some View {
        VStack(spacing: 12) {
            SectionLabel("Macs")
            if remote.macs.isEmpty {
                RowGroup {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for Throwcast…").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(14)
                }
            } else {
                targets(remote.macs, icon: "laptopcomputer")
            }
            SectionLabel("TVs")
            if remote.tvTargets.isEmpty {
                RowGroup {
                    HStack(spacing: 10) {
                        if remote.lookingForTVs { ProgressView() }
                        Text(remote.lookingForTVs ? "Looking for TVs…" : "No TV with Throwcast open").foregroundStyle(.secondary)
                        Spacer()
                        if !remote.lookingForTVs { Button("Look Again") { remote.findTVs() } }
                    }
                    .padding(14)
                    HStack {
                        TextField("TV address, like 192.168.1.40", text: $address)
                            .keyboardType(.decimalPad).textContentType(.none)
                        Button("Add") { remote.addTV(host: address.trimmingCharacters(in: .whitespaces)) }
                            .disabled(address.split(separator: ".").count != 4)
                    }
                    .padding(14)
                }
            } else {
                targets(remote.tvTargets, icon: "tv")
            }
            Caption("With the Mac app open, choose your Mac. When Chrome casts a tab by itself, choose the TV. Everything needs to be on the same Wi-Fi.")
            if let notice = remote.notice { Caption(notice).foregroundStyle(.red) }
        }
    }

    private func targets(_ list: [Mac], icon: String) -> some View {
        RowGroup {
            ForEach(list) { target in
                Button { remote.connect(target) } label: {
                    HStack {
                        Image(systemName: icon).foregroundStyle(Design.accent)
                        Text(target.name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(14).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func pairing(_ code: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.iphone").font(.system(size: 44)).foregroundStyle(Design.accent).padding(.top, 24)
            Text("Allow this iPhone on your Mac").font(.system(size: 17, weight: .semibold))
            Text(code.map(String.init).joined(separator: " "))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            Caption("Your Mac is asking whether to allow this iPhone. Choose Allow there if it shows the same code.")
                .multilineTextAlignment(.center)
            Button("Cancel") { remote.disconnect() }.padding(.top, 8)
        }
    }

    private func message(_ text: String, action: String, _ run: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.secondary).padding(.top, 32)
            Text(text).multilineTextAlignment(.center)
            PrimaryButton(title: action, action: run)
            Button("Choose Another Mac") { remote.disconnect() }
        }
    }
}

/// The 6-digit code the TV shows.
struct CodeEntry: View {
    @Environment(Remote.self) private var remote
    let triesLeft: Int?
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv").font(.system(size: 44)).foregroundStyle(Design.accent).padding(.top, 24)
            Text("Type the code on your TV").font(.system(size: 17, weight: .semibold))
            TextField("000000", text: $code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .focused($focused)
                .onChange(of: code) { _, new in
                    code = String(new.filter(\.isNumber).prefix(6))
                    if code.count == 6 { remote.submit(code: code); code = "" }
                }
            if let triesLeft { Caption("That code didn't match. \(triesLeft) \(triesLeft == 1 ? "try" : "tries") left.").multilineTextAlignment(.center) }
            else { Caption("Your TV shows a code while this screen is open.").multilineTextAlignment(.center) }
            Button("Cancel") { remote.disconnect() }.padding(.top, 8)
        }
        .onAppear { focused = true }
        .sensoryFeedback(.error, trigger: triesLeft)
    }
}

// MARK: The remote

struct RemoteScreen: View {
    @Environment(Remote.self) private var remote
    @State private var source: Source = .screen
    @State private var window: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                status
                if let playback = remote.playback {
                    NowPlaying(playback: playback)
                }
                if remote.controlsTV {
                    if remote.casting, let settings = remote.settings { CastSettingsView(settings: settings) }
                } else if let mac = remote.macSettings {
                    MacSettingsView(settings: mac)
                }
                if remote.controlsTV {
                    if !remote.casting && remote.playback == nil {
                        Caption("Nothing is casting. Start a cast from Chrome with the Throwcast extension, and its controls show up here.")
                    }
                } else if !remote.casting && remote.playback == nil {
                    chromeCast
                    tvPicker
                    sourcePicker
                }
                action
                if let notice = remote.notice ?? remote.failure {
                    Caption(notice).foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .navigationTitle(remote.macName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !remote.controlsTV {
                        Button("Look for TVs Again", systemImage: "arrow.clockwise") { remote.rescan() }
                    }
                    if remote.controlsTV {
                        ForEach(remote.macs) { mac in
                            Button("Switch to \(mac.name)", systemImage: "laptopcomputer") { remote.connect(mac) }
                        }
                    } else {
                        ForEach(remote.tvTargets) { tv in
                            Button("Switch to \(tv.name)", systemImage: "tv") { remote.connect(tv) }
                        }
                    }
                    Button("Disconnect", systemImage: "xmark.circle") { remote.disconnect() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onChange(of: source) { _, new in if new == .window { remote.refreshWindows() } }
    }

    /// A tab Chrome casts by itself goes straight to the TV, not through the Mac, so its controls are on the TV.
    @ViewBuilder private var chromeCast: some View {
        RowGroup {
            Button {
                if let tv = remote.tvTargets.first { remote.connect(tv) } else { remote.findTVs() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(Design.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Casting a tab from Chrome?").foregroundStyle(.primary)
                        Text(remote.tvTargets.first.map { "Control it on \($0.name)" } ?? (remote.lookingForTVs ? "Looking for your TV…" : "Find the TV"))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if remote.lookingForTVs { ProgressView() } else { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                }
                .padding(14).contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var status: some View {
        let tv = remote.tvs.first { $0.host == remote.selectedTV }
        HStack {
            if remote.casting {
                LivePill(text: remote.castState == "connecting" ? "Connecting…" : "Live on \(tv?.name ?? "TV")")
            } else if remote.playback?.direct == true {
                LivePill(text: "Playing on \(tv?.name ?? "TV")")
            } else {
                Text("Not casting").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            if let stats = remote.stats {
                Text("\(Int(stats.fps)) fps · \(Int(stats.mbps)) Mbps").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 4)
    }

    private var tvPicker: some View {
        VStack(spacing: 8) {
            SectionLabel("TV")
            RowGroup {
                if remote.tvs.isEmpty {
                    Text("No TV found yet").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(remote.tvs) { tv in
                    Button { remote.selectTV(tv.host) } label: {
                        HStack {
                            Image(systemName: "tv").foregroundStyle(Design.accent)
                            Text(tv.name).foregroundStyle(.primary)
                            Text(tv.resolution).font(.system(size: 13)).foregroundStyle(.secondary)
                            Spacer()
                            if remote.selectedTV == tv.host { Image(systemName: "checkmark").foregroundStyle(Design.accent).fontWeight(.semibold) }
                        }
                        .padding(14).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(remote.selectedTV == tv.host ? .isSelected : [])
                }
            }
        }
    }

    private var sourcePicker: some View {
        VStack(spacing: 8) {
            SectionLabel("Show")
            Segments(options: Source.allCases.map { ($0, $0.label) }, selection: $source)
            Caption(captionFor(source))
            if source == .window { windowList }
        }
    }

    private func captionFor(_ source: Source) -> String {
        switch source {
        case .screen: "Your Mac's screen on the TV, at the TV's resolution."
        case .mirror: "The TV shows exactly what the Mac shows."
        case .extend: "The TV becomes a second display."
        case .window: "One window, shaped to fit the TV."
        }
    }

    private var windowList: some View {
        RowGroup {
            if remote.windowsLoading && remote.windows.isEmpty {
                HStack { ProgressView(); Text("Finding windows…").foregroundStyle(.secondary); Spacer() }.padding(14)
            }
            ForEach(remote.windows) { item in
                Button { window = item.id } label: {
                    HStack(spacing: 10) {
                        if let icon = item.icon { Image(uiImage: icon).resizable().frame(width: 24, height: 24) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).lineLimit(1).foregroundStyle(.primary)
                            Text(item.hidden ? "\(item.app) · hidden" : item.app).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if window == item.id { Image(systemName: "checkmark").foregroundStyle(Design.accent).fontWeight(.semibold) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var action: some View {
        if remote.casting || remote.playback != nil {
            PrimaryButton(title: "Stop", role: .destructive) { remote.stop() }
                .sensoryFeedback(.impact, trigger: remote.castState)
        } else if remote.controlsTV {
            EmptyView()
        } else {
            PrimaryButton(title: "Show on TV") {
                remote.notice = nil
                remote.start(source, window: source == .window ? window : nil)
            }
            .disabled(remote.selectedTV == nil || (source == .window && window == nil))
            .opacity(remote.selectedTV == nil || (source == .window && window == nil) ? 0.45 : 1)
        }
    }
}

// MARK: Now playing

struct NowPlaying: View {
    @Environment(Remote.self) private var remote
    let playback: Playback
    @State private var scrub: Double?
    @State private var volume: Double = 1

    var body: some View {
        VStack(spacing: 14) {
            Text(playback.title).font(.system(size: 17, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
            if playback.duration > 0 && !playback.live {
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { scrub ?? playback.time }, set: { scrub = $0 }), in: 0 ... max(playback.duration, 1)) { editing in
                        if !editing, let scrub { remote.seek(to: scrub); self.scrub = nil }
                    }
                    .accessibilityLabel("Position")
                    HStack {
                        Text(clock(scrub ?? playback.time))
                        Spacer()
                        Text("-" + clock(playback.duration - (scrub ?? playback.time)))
                    }
                    .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if playback.live {
                Button { remote.goLive() } label: {
                    Text("LIVE").font(.system(size: 13, weight: .bold)).foregroundStyle(Design.live)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(Design.live.opacity(0.15), in: .capsule)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Go to live")
            }
            HStack(spacing: remote.tabCasting ? 16 : 28) {
                if remote.tabCasting { CircleButton(icon: "backward.end.fill", label: "Previous video") { remote.previous() } }
                CircleButton(icon: "gobackward.10", label: "Back 10 seconds") { remote.jump(-10) }
                CircleButton(icon: playback.paused ? "play.fill" : "pause.fill", label: playback.paused ? "Play" : "Pause", size: 60, primary: true) { remote.togglePlay() }
                CircleButton(icon: "goforward.10", label: "Forward 10 seconds") { remote.jump(10) }
                if remote.tabCasting { CircleButton(icon: "forward.end.fill", label: "Next video") { remote.next() } }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: playback.paused)
            if !playback.direct {
                RowGroup {
                    SliderRow(low: "speaker.fill", high: "speaker.wave.3.fill", label: "Volume", value: $volume) { remote.setVolume($0) }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Design.panelRadius))
        .onAppear { volume = playback.volume ?? 1 }
        .onChange(of: playback.volume) { _, new in if let new { volume = new } }
    }
}

// MARK: The extension's settings, through the TV

/// What the extension's popup offers during a cast: picture style and sliders, picture size, and the stream.
struct CastSettingsView: View {
    @Environment(Remote.self) private var remote
    let settings: CastSettings
    /// A Mac cast: the picture only, since the Mac app keeps size and stream settings itself.
    var pictureOnly = false
    @State private var look = Look()
    @State private var volume = 1.0
    @State private var panel = "picture"

    var body: some View {
        if pictureOnly {
            VStack(spacing: 8) {
                if remote.playback == nil {
                    // A screen or window cast: the sound the Mac sends to the TV.
                    SectionLabel("Sound on the TV")
                    RowGroup {
                        SliderRow(low: "speaker.fill", high: "speaker.wave.3.fill", label: "Volume", value: $volume) { remote.setVolume($0) }
                    }
                }
                SectionLabel("Picture")
                picture
            }
            .onAppear { look = settings.look }
            .onChange(of: settings.look) { _, new in look = new }
        } else {
            full
        }
    }

    private var full: some View {
        VStack(spacing: 8) {
            SectionLabel("Picture Size")
            Segments(options: [("contain", "Show All"), ("cover", "Fill"), ("fill", "Stretch")],
                     selection: Binding(get: { settings.size }, set: { remote.setSize($0) }))
            Segments(options: [("picture", "Picture"), ("stream", "Stream")], selection: $panel).padding(.top, 12)
            if panel == "picture" { picture } else { stream }
        }
        .onAppear { look = settings.look }
        .onChange(of: settings.look) { _, new in look = new }
    }

    @ViewBuilder private var picture: some View {
        let current = Look.styles.first { look.same($0.2) }?.0 ?? "custom"
        Segments(options: Look.styles.map { ($0.0, $0.1) } + (current == "custom" ? [("custom", "Custom")] : []),
                 selection: Binding(get: { current }, set: { key in
                     if let style = Look.styles.first(where: { $0.0 == key })?.2 { look = style; remote.setLook(style) }
                 }))
        RowGroup {
            slider("Brightness", \.brightness, -0.25 ... 0.25)
            slider("Contrast", \.contrast, 0.75 ... 1.25)
            slider("Color", \.saturation, 0 ... 2)
            slider("Warmth", \.warmth, -1 ... 1)
            // The popup's Shadows is 2 − gamma, so right is brighter shadows.
            HStack {
                Text("Shadows").frame(width: 92, alignment: .leading)
                Slider(value: Binding(get: { 2 - look.gamma }, set: { look.gamma = 2 - $0 }), in: 0.8 ... 1.2) { editing in
                    if !editing { remote.setLook(look) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        Button("Reset Picture") { look = Look(); remote.setLook(look) }.font(.system(size: 15)).padding(.top, 4)
    }

    private func slider(_ name: String, _ key: WritableKeyPath<Look, Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(name).frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { look[keyPath: key] }, set: { look[keyPath: key] = $0 }), in: range) { editing in
                if !editing { remote.setLook(look) }
            }
            .accessibilityLabel(name)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private var stream: some View {
        RowGroup {
            setting("Quality") {
                Segments(options: [("4k", "4K"), ("1440", "1440p"), ("1080", "1080p")],
                         selection: Binding(get: { settings.quality }, set: { remote.setStream("quality", $0) }))
            }
            setting("Bitrate") {
                Segments(options: [("auto", "Auto"), ("20", "20"), ("40", "40"), ("60", "60")],
                         selection: Binding(get: { settings.bitrate }, set: { remote.setStream("bitrate", $0 == "auto" ? "auto" as Any : (Int($0) ?? 20) as Any) }))
            }
            setting("Frame Rate") {
                Segments(options: [(60, "60"), (30, "30")], selection: Binding(get: { settings.fps }, set: { remote.setStream("fps", $0) }))
            }
            setting("Delay") {
                Segments(options: [(400, "Smooth"), (100, "Low")], selection: Binding(get: { settings.delay }, set: { remote.setStream("delay", $0) }))
            }
        }
        Caption("Higher bitrate is sharper but needs stronger Wi-Fi. Smooth rides out Wi-Fi hiccups; Low feels quicker. A change restarts the stream, and the TV takes a moment.")
    }

    private func setting<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.system(size: 13)).foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}


// MARK: The Mac app's settings

/// Everything the Mac app's window offers, so the Mac can stay closed: what's set here is set there.
struct MacSettingsView: View {
    @Environment(Remote.self) private var remote
    let settings: MacSettings
    @State private var volume = 1.0
    @State private var look = Look()
    @State private var panel = "stream"

    var body: some View {
        VStack(spacing: 8) {
            if remote.playback == nil {
                SectionLabel("Sound on the TV")
                RowGroup {
                    SliderRow(low: "speaker.fill", high: "speaker.wave.3.fill", label: "Volume", value: $volume) { remote.setVolume($0) }
                }
            }
            Segments(options: [("stream", "Stream"), ("picture", "Picture")], selection: $panel).padding(.top, 12)
            if panel == "stream" { stream } else { picture }
        }
        .onAppear {
            volume = settings.volume; look = settings.look
            #if DEBUG
            if Remote.demoScreen == "picture" { panel = "picture" }
            #endif
        }
        .onChange(of: settings.volume) { _, new in volume = new }
        .onChange(of: settings.look) { _, new in look = new }
    }

    @ViewBuilder private var stream: some View {
        RowGroup {
            row("Quality") {
                Segments(options: [("good", "Good"), ("better", "Better"), ("best", "Best")],
                         selection: Binding(get: { settings.quality }, set: { remote.setMac("quality", $0) }))
            }
            if !settings.resolutions.isEmpty {
                menuRow("Resolution", settings.resolutions.first { $0.value == String(settings.height) }?.title ?? "\(settings.height)p") {
                    ForEach(settings.resolutions, id: \.self) { r in Button(r.title) { remote.setMac("height", Int(r.value) ?? 1080) } }
                }
            }
            menuRow("Bitrate", "\(settings.bitrate) Mbps") {
                ForEach(settings.bitrates.isEmpty ? [10, 20, 40, 60, 80] : settings.bitrates, id: \.self) { b in Button("\(b) Mbps") { remote.setMac("bitrate", b) } }
            }
            row("Frame Rate") {
                Segments(options: [(24, "24"), (30, "30"), (60, "60"), (120, "120")],
                         selection: Binding(get: { settings.fps }, set: { remote.setMac("fps", $0) }))
            }
            row("Playback") {
                Segments(options: [("smooth", "Smooth"), ("balanced", "Balanced"), ("instant", "Instant")],
                         selection: Binding(get: { settings.playback }, set: { remote.setMac("playback", $0) }))
            }
            row("Connection") {
                Segments(options: [(false, "TCP · Reliable"), (true, "UDP · Fastest")],
                         selection: Binding(get: { settings.udp }, set: { remote.setMac("udp", $0) }))
            }
            if settings.codecs.count > 1 {
                row("Codec") {
                    Segments(options: settings.codecs.map { ($0, $0.uppercased()) },
                             selection: Binding(get: { settings.codec }, set: { remote.setMac("codec", $0) }))
                }
            }
            Toggle("10-bit color", isOn: Binding(get: { settings.tenBit }, set: { remote.setMac("tenBit", $0) }))
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        Caption("These are the Mac app's settings. A change while casting restarts the cast with it, as it does on the Mac.")
    }

    @ViewBuilder private var picture: some View {
        if !settings.profiles.isEmpty {
            RowGroup {
                menuRow("Profile", settings.profiles.first { $0.value == settings.profile }?.title ?? settings.profile) {
                    ForEach(settings.profiles, id: \.self) { p in Button(p.title) { remote.setMac("profile", p.value) } }
                }
            }
        }
        RowGroup {
            slider("Brightness", \.brightness, -0.25 ... 0.25)
            slider("Contrast", \.contrast, 0.75 ... 1.25)
            slider("Color", \.saturation, 0 ... 2)
            slider("Warmth", \.warmth, -1 ... 1)
            slider("Gamma", \.gamma, 0.8 ... 1.2)
        }
        Button("Reset Picture") { look = Look(); remote.setLook(look) }.font(.system(size: 15)).padding(.top, 4)
    }

    private func slider(_ name: String, _ key: WritableKeyPath<Look, Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(name).frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { look[keyPath: key] }, set: { look[keyPath: key] = $0 }), in: range) { editing in
                if !editing { remote.setLook(look) }
            }
            .accessibilityLabel(name)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func row<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.system(size: 13)).foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func menuRow<Items: View>(_ name: String, _ value: String, @ViewBuilder _ items: () -> Items) -> some View {
        Menu { items() } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                Text(value).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(14).contentShape(.rect)
        }
        .tint(.primary)
    }
}
