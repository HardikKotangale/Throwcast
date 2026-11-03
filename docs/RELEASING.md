# Releasing

For maintainers. People installing Throwcast only need the DMG from a release.

## Build the DMG

```sh
scripts/build-dmg.sh   # dist/Throwcast.dmg and dist/Throwcast-<version>.dmg
```

It opens to a designed install window: Throwcast, an arrow, and Applications, with the browser extension and a read-me below. The layout lives in `scripts/dmg/` and is built with `dmgbuild`, which the script installs into `dist/.venv` the first time. `scripts/dmg/background.py` and `download-button.py` redraw the art, and need Pillow.

## Sign and notarize

Without a Developer ID, the app is signed ad hoc. That's fine for testing, but on other Macs it needs a one-time **Open Anyway** in **System Settings > Privacy & Security**. To make it open with a double-click, sign it with a **Developer ID Application** certificate, which needs the paid Apple Developer Program, and notarize it:

```sh
xcrun notarytool store-credentials throwcast   # once
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=throwcast scripts/build-dmg.sh
```

## Publish

1. Bump `version:` in `app/pubspec.yaml`.
2. Build the DMG and open it once to check the window and the app's version.
3. Note its checksum for the release notes: `shasum -a 256 dist/Throwcast.dmg`.
4. Create a GitHub release and attach `dist/Throwcast.dmg` under that exact name, so the README's download button keeps working.
5. Say in the notes whether this build is notarized.

Never attach `tv/dist/Throwcast.wgt`. It's signed with your own Samsung certificate and won't install on anyone else's TV.
