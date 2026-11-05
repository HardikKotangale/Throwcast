# Installing Throwcast

There are three parts: the Mac app, the TV app and the browser extension. The TV app is installed once from your Mac, because it isn't in Samsung's app store. To cast only browser tabs, the TV app and the extension are enough: the extension doesn't need the Mac app.

## 1. The Mac app

**From the download:** open `Throwcast.dmg` and drag Throwcast to Applications. Builds that aren't notarized need a one-time **Open Anyway** in **System Settings > Privacy & Security**.

**After updating to a new version:** macOS sees each build that isn't notarized as a new app, so Screen Recording stops working even though Throwcast still looks allowed. In **System Settings > Privacy & Security > Screen Recording**, select Throwcast, remove it with **−**, then open Throwcast and allow it again.

**From source:** you need [Xcode](https://apps.apple.com/app/xcode/id497799835), [Flutter](https://docs.flutter.dev/get-started/install/macos) and [CocoaPods](https://cocoapods.org).

1. **Optional:** create a signing certificate so macOS remembers your permissions across rebuilds. In **Keychain Access**, choose **Certificate Assistant > Create a Certificate…**, name it exactly `Throwcast Local Signing` and set **Certificate Type** to **Code Signing**.
2. Run `scripts/install-app.sh`. It installs `/Applications/Throwcast.app`.

The first time it opens, follow the checklist in its window: allow **Screen Recording**, reopen, and allow **Local Network** if macOS asks.

## 2. The TV app

You need [Tizen Studio](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/installing-tv-sdk.html) in `~/tizen-studio`, with the **TV Extensions**, and a free Samsung account.

1. **Developer Mode on the TV:** open **Apps**, press **1 2 3 4 5** on the remote, switch **Developer mode** on, enter your Mac's IP address, then turn the TV off and on.
2. **Signing profile:** in Tizen Studio, open **Tools > Certificate Manager**, add a **Samsung** profile, sign in, and add your TV when asked for devices.
3. **Package and install:**

   ```sh
   scripts/package-tv.sh <your-profile-name>
   scripts/install-tv.sh <tv-ip-address>
   ```

Throwcast then appears in the TV's **Apps**. The Mac app or the browser extension opens it when you cast. The player is prebuilt in `tv/app`, so Docker is only needed if you change `tv/wasm/player.cpp`.

This is needed once even if you'll only use the browser extension: Samsung installs only apps signed for your own TV, so the TV app can't come ready-made in the download.

### Updating the TV app

A new release can need a new TV app too; its release notes say so. 1.1.1 does, because the extension casts to a server inside the TV app. Get the new version of this project (download it again, or `git pull`), then run the same two commands:

```sh
scripts/package-tv.sh <your-profile-name>
scripts/install-tv.sh <tv-ip-address>
```

The new version replaces the old one; Developer Mode and the signing profile stay as they are.

- **"Fail install" or "problem to transfer package":** run `install-tv.sh` again; it starts a fresh connection to the TV.
- **The TV doesn't connect at all:** check that Developer Mode is still on with this Mac's IP address. A new IP address from your router, or a TV reset, needs step 1 again.
- **Certificate errors:** the Samsung certificate may have expired. Renew the profile in **Tools > Certificate Manager**, then package and install again.

## 3. The browser extension

1. Open `chrome://extensions` or `brave://extensions` and turn on **Developer mode**.
2. Choose **Load unpacked** and select the `extension` folder.
3. Pin Throwcast to the toolbar.

After an update, stop any cast, click **reload ↻** on the extension, and refresh the pages you'll cast.

## Using it

- **Your Mac:** open Throwcast, choose **What to Show**, and press **Show on TV**.
- **A browser tab:** click the extension and press **Show This Tab on TV**. The first time, choose your TV: the extension finds it on your Wi-Fi, or takes its address. Chrome then casts the tab to the TV by itself, with no Mac app needed, in H.264 at up to 4K and 60 FPS.
  - The TV shows the whole page, so the site works as usual. Full screen on a video (**F**, a double-click or the player's button) fills the TV with just the video; **Escape** goes back. **Whole Page / Just the Video** in the extension does the same.
  - **Picture**: Natural, Video, Cinema and Vivid styles, your own saved styles, and Brightness, Contrast, Color, Warmth and Shadows, all live on the TV.
  - **Stream**: quality (4K, 1440p, 1080p), bitrate (Auto, a preset or typed), frame rate, delay, and a Wi-Fi test that suggests a bitrate. A change during a cast restarts the stream in a couple of seconds.
  - The volume slider sets the TV's volume, which no site can reset. **Stop**, or closing the tab, ends the cast; nothing keeps running afterwards.
- **A browser window with One Window:** the page shows on the TV as it is. Go full screen on a video (**F**, a double-click or the player's button) and it fills the TV instead, with play controls in Throwcast; **Escape** or full screen again goes back. This needs the extension too.
- **On the TV remote:** **Enter** shows picture stats, and **Back** closes the app.

## Uninstalling

macOS keeps an app's permissions and settings after the app is deleted, so remove Throwcast from inside it: **More Options > Uninstall Throwcast…**. It resets its Screen Recording and other permissions, deletes your settings and color profiles, and moves the app to the Trash.

Already deleted the app? Run this in Terminal to remove what it left behind:

```sh
tccutil reset All local.throwcast.app
rm -rf ~/Library/Application\ Support/Throwcast
defaults delete local.throwcast.app
```

The TV app and the browser extension are removed separately: on the TV, from **Apps**, and in the browser, with **Remove** on its extensions page.
