<div align="center">

<img src="docs/assets/icon.png" width="128" alt="Throwcast icon">

# Throwcast

**Your Mac on your Samsung TV in true 4K, at 60 FPS, over Wi-Fi.**

Cast your screen, a window, a second display or one browser tab.<br>
No stick, no cable.

<a href="../../releases/latest/download/Throwcast.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/download-macos-dark.png">
    <img src="docs/assets/download-macos.png" alt="Download Throwcast for macOS" width="336">
  </picture>
</a>

[![Resolution](https://img.shields.io/badge/up%20to-4K%2060%20FPS-e4572e)](docs/DETAILS.md#resolution-4k-2k-or-1080p)
[![Mac](https://img.shields.io/badge/Mac-macOS%2015%2B-blue)](docs/INSTALL.md)
[![Tested on](https://img.shields.io/badge/tested%20on-Samsung%20AU8000-1428a0)](docs/DETAILS.md#tested-hardware)
[![License](https://img.shields.io/badge/license-GPL--3.0-3fb950)](LICENSE)

</div>

<img src="docs/assets/demo.webp" width="100%" alt="Choosing what to show; picking 4K from Full HD, 2K and 4K; choosing the delay, TCP or UDP, and the Mac's encoder; casting the open-source film Big Buck Bunny with play controls; and the frames the TV received at 3840 by 2160 and 59.5 FPS with no dropped frames">

> [!NOTE]
> Only tested on a **Samsung AU8000 55"** (Tizen 6.5). Other Samsung TVs from 2020 on should work but haven't been tried, so [let us know](../../issues) how yours does.

## Why Throwcast

- **Real 4K, 2K or 1080p.** The TV gets its own resolution, not a stretched-up picture.
- **Steady 60 FPS.** Measured on the TV, 59.5 FPS on average with 0 dropped frames ([details](docs/DETAILS.md#a-real-cast-measured)).
- **Delay you choose.** Smooth (0.4 s) for films, Balanced (0.1 s) for everyday use, or Instant (0.03 s) for mouse and typing, over TCP or UDP ([details](docs/DETAILS.md#delay-and-network)).
- **Any Apple silicon Mac.** Throwcast checks which hardware encoders your Mac has, HEVC or H.264, and offers only those.
- **Any browser tab.** Just the video, filling the TV, on almost any site, live streams included.
- **Sound where it belongs.** A cast tab plays on the TV, keeps playing after the Mac sleeps, and your Mac keeps its own sound.
- **Simple for everyone.** Good, Better or Best, five color styles, play controls on your Mac, and every control works from the keyboard and with VoiceOver.

## Get started

1. **Mac:** download the DMG above and drag Throwcast to Applications.
2. **TV:** turn on Developer Mode and install the TV app from your Mac ([guide](docs/INSTALL.md#2-the-tv-app)).
3. **Browser:** load the extension in Chrome or Brave ([guide](docs/INSTALL.md#3-the-browser-extension)).

Then open Throwcast and press **Show on TV**.

## If it doesn't connect

| Message on your Mac | What to do |
| --- | --- |
| **Throwcast isn't installed on this TV yet.** | Install the TV app ([guide](docs/INSTALL.md#2-the-tv-app)). |
| **Couldn't open Throwcast on the TV.** | Open Throwcast from the TV's Apps screen, then press **Show on TV** again. |
| **The TV didn't connect.** | One Mac casts at a time, and the first one keeps the TV. If someone else is casting, wait until they stop. |

## Learn more

- [Install guide](docs/INSTALL.md): every step, building from source, and uninstalling cleanly
- [How it works](docs/DETAILS.md): resolution, delay and network, the measured cast, how it got to 60 FPS, privacy, permissions and limits
- [Notices](NOTICE.md): credits, licenses and trademarks
- [Releasing](docs/RELEASING.md): building, signing and publishing the DMG, for maintainers

<sub>Demo film: <i>Big Buck Bunny</i> © Blender Foundation, <a href="https://creativecommons.org/licenses/by/3.0/">CC BY 3.0</a>. Throwcast is an independent project, not affiliated with Samsung, Apple or Google. See <a href="NOTICE.md">Notices</a>.</sub>

## License

Copyright © 2026 Hardik Kotangale. Throwcast is free software under the [GNU General Public License v3.0](LICENSE): use it, change it and share it, even commercially, as long as anything you distribute based on it is shared under the same license, with its source. Credits for the demo film and other open-source pieces are in [Notices](NOTICE.md).
