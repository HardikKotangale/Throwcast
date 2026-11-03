# How Throwcast works

## Resolution: 4K, 2K or 1080p

The headline feature. Throwcast reads your TV's own resolution and offers every size up to it, so a 4K TV gets a real 4K picture, pixel for pixel.

| Choice | Size | What you get |
| --- | --- | --- |
| **4K** | 3840 × 2160 | The sharpest picture, every pixel of a 4K TV. Text stays crisp from the couch |
| **2K** | 2560 × 1440 | Sharper than Full HD, with less data, for Wi-Fi that can't keep up with 4K |
| **Full HD** | 1920 × 1080 | Larger text and the lightest load, for weak Wi-Fi or a 1080p TV |

- **Fill the TV** runs your Mac at the chosen size, so apps lay out for the TV and text is drawn sharp, not scaled up afterward. At 2K and 4K it uses Retina scaling, like a Mac's own display.
- **Good, Better and Best** pick the resolution and bitrate together, at Full HD, 2K and your TV's maximum. Or set each one under **More Options > Resolution**.
- **10-bit color** and **HDR** (BT.2020) come along at every size. HDR falls back to standard color on a TV without it.
- The picture is encoded on your Mac's hardware encoder, at 24, 30, 60 or 120 FPS. **More Options > Video Encoder** lists only the encoders that Mac really has: HEVC (best quality for the data, 10-bit and HDR) or H.264 (most compatible, 8-bit). If a saved choice isn't available on the Mac it runs on, Throwcast picks one that is.

## Delay and network

**More Options > Playback** sets how far the TV runs behind your Mac. A bigger buffer hides Wi-Fi hiccups; a smaller one feels more direct.

| Playback | Delay | Best for |
| --- | --- | --- |
| **Smooth** | 0.4 s | Films and live streams. Hiccups never show |
| **Balanced** | 0.1 s | Everyday use |
| **Instant** | 0.03 s | Mouse and typing, like a second display |

**More Options > Network Mode** picks how frames travel:

- **TCP · Reliable** delivers every byte in order. When one packet is lost, everything behind it waits for the resend, which a large buffer hides but a small one shows as a freeze.
- **UDP · Fastest** never waits. Each frame is cut into packets with one repair packet per eight, so the TV rebuilds a single lost packet by itself, and asks the Mac again for anything else. A frame that still can't be finished in time is skipped, and the TV asks for a fresh key frame.

Both use Wi-Fi's video priority queue. Measured on the AU8000 over 40 seconds of full motion:

| Setting | Frames per second | Frames lost |
| --- | --- | --- |
| Balanced over TCP | 60.0, 47 ms worst gap | 0 |
| Balanced over UDP | 59.6 | 0–2 |
| Instant over UDP | about 58.5 | about 12 |
| Instant over TCP | freezes up to 0.45 s | 0 |

So: Smooth or Balanced over TCP for watching, Instant over UDP for working.

## A real cast, measured

*Big Buck Bunny* is an open-source 60 FPS film, © Blender Foundation, licensed [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). Its 1080p copy from [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Big_Buck_Bunny_4K.webm) played in a Brave tab and was cast with **Show This Tab on TV** at **Best** (4K, 60 Mbps).

| Measured over 20 seconds | Result |
| --- | --- |
| Resolution sent to the TV | **3840 × 2160** |
| Frames per second shown on the TV | **59.5 average**, 56 lowest, 61 highest |
| Frames dropped | **0** |
| Network delay | 6 ms typical |
| Film's own frame rate in the browser | 60.2 decoded per second |

The TV counts each frame as it arrives and reports once a second, so a reading of 61 is two frames landing just either side of a one-second mark.

## Making it smooth

Early versions held 54 to 58 FPS with a stutter about once a second. Measuring a full-motion test pattern, frame by frame from the Mac to the TV, found three separate causes:

1. **Capture timing:** asking macOS for exactly 60 frames a second made it skip one whenever a frame arrived a hair early. It now asks for 120 and sends 60.
2. **Send timing:** the timer that sends frames sat on the edge of each frame slot, so a slightly late tick lost a frame. It now ticks in the middle of the slot.
3. **Wi-Fi hiccups:** the Mac threw frames away whenever Wi-Fi backed up. The TV now keeps 0.4 seconds in hand and the Mac waits instead.

| Measured at 35 Mbps | Before | After |
| --- | --- | --- |
| Frames encoded per second | 57–58 | **60** |
| Typical gap between frames on the TV | 34 ms | **19 ms** |
| Frames thrown away | 39 in about 23 s | **0** |

## Tested hardware

| | |
| --- | --- |
| **TV** | Samsung AU8000 55" (UN55AU8000FXZA), Tizen 6.5, 4K at 60 Hz |
| **Mac** | MacBook Pro with M4 Pro, macOS 26 |
| **Browser** | Google Chrome |
| **Network** | Mac and TV on the same home Wi-Fi |

Nothing else has been tested: other Samsung models, Brave, other Macs, or Ethernet.

## Requirements

- **Mac:** macOS 15 or later, on Apple silicon. Only tested on an M4 Pro.
- **TV:** a Samsung TV from 2020 or later with Developer Mode. Only tested on the AU8000.
- **Browser:** Chrome 123 or later, or Brave, for tab casting.
- **Network:** the Mac and the TV on the same local network.

## Permissions

- **Screen Recording** is how the Mac app sees what to send. Nothing is saved.
- **Local Network** lets it find the TV and stream to it.
- **The extension** reads the page you cast so it can fill the TV and control the video, and captures only that tab's sound. Chrome shows that the tab is shared while it does.

## Privacy

Throwcast has no account, no servers and no analytics. Everything stays between your Mac, your browser and your TV on your own network.

- **The Mac app** sends the picture and sound only to the TV you chose, and only it may connect.
- **The browser extension** runs on every site so it can find and fill the video on whichever tab you cast. It reads that page's video and its own settings, and talks only to the Throwcast app on your Mac. The cast tab's sound goes to the app over a connection that accepts only this Mac. **Play on TV**, offered when a page has a plain video file or stream link, passes that address and the request details the site needs, including cookies, from your browser to the app, which uses them only to fetch that one video for your TV.

## Responsible use

Throwcast shows on your TV what is already playing on your Mac. It doesn't break or work around copy protection: video protected with DRM usually shows black, and that's expected. Respect the terms of the sites and services you cast from.

## Limits

- **Unencrypted stream:** anyone who can capture traffic on your network could see it, so don't cast private content on a shared network. The Mac only streams to the TV you chose.
- **One TV at a time, and one Mac per TV.** The Mac that connects first keeps the TV until its cast ends. Another Mac that tries meanwhile waits up to 25 seconds, then says the TV didn't connect, and the cast already playing isn't interrupted.
- **Protected video:** DRM video from some services usually shows black.
- **Mission Control:** the TV holds the last picture until it closes, while the sound keeps playing.
- **Smooth delay:** Smooth runs about 0.4 seconds behind, so a pause on the Mac takes a moment to reach the TV. Pick **Balanced** or **Instant** under **Playback** for less.
- **Instant over Wi-Fi:** a 0.03 s buffer leaves time for only one resend, so on busy Wi-Fi a few frames a minute may be skipped.
- **Private macOS API:** **Fill the TV**, **Extra Screen** and tab casting use one, so a macOS update could break them. **Keep Shape** and **One Window** don't depend on it.
- **Large networks:** finding devices assumes a home-sized network. On larger ones, type the TV's IP address.

## Development

```sh
swift test                 # engine tests: color round trip on the hardware encoder, UDP packet layout, H.264, crop
(cd app && flutter test)   # app layouts at normal and large text, color profiles, keyboard use
clang++ -std=c++17 tv/wasm/udp_frames_test.cpp -o /tmp/udp && /tmp/udp   # the TV's UDP frame rebuilder
.build/debug/Throwcast --cast <tv-ip> --seconds 20 --source mirror --bitrate 40 \
  --playback balanced --transport udp --codec hevc   # no UI, prints stats every second
```

`app/` is the Flutter window. `app/plugins/throwcast_engine` is the Swift engine, built into the app as a plugin: ScreenCaptureKit capture, the hardware encoder and the network stream all run inside the app, so macOS has one app to approve. `tv/` is the Samsung receiver, and `extension/` is the browser extension.
