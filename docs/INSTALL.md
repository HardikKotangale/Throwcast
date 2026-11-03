# Installing Throwcast

There are three parts: the Mac app, the TV app and the browser extension. The TV app is installed once from your Mac, because it isn't in Samsung's app store.

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

Throwcast then appears in the TV's **Apps**. The Mac app opens it when you cast. The player is prebuilt in `tv/app`, so Docker is only needed if you change `tv/wasm/player.cpp`.

## 3. The browser extension

1. Open `chrome://extensions` or `brave://extensions` and turn on **Developer mode**.
2. Choose **Load unpacked** and select the `extension` folder.
3. Pin Throwcast to the toolbar.

After an update, stop any cast, click **reload ↻** on the extension, and refresh the pages you'll cast.

## Using it

- **Your Mac:** open Throwcast, choose **What to Show**, and press **Show on TV**.
- **A browser tab:** keep Throwcast open, click the extension on the page, and press **Show This Tab on TV**. The tab moves to a private display that only the TV sees. **Stop Casting** in the app or the extension brings it back, and closing the tab ends the cast too.
- **On the TV remote:** **Enter** shows picture stats, and **Back** closes the app.
