# MacBridge

Control one Mac from another, from anywhere. One app on both Macs; a small server you host introduces them, then screen and input travel directly between the two Macs over WebRTC.

Status: early; used between Macs on a private network (Tailscale), not yet tried over the open internet. Working name.

## Layout

| Path | What |
|---|---|
| `App/` | Mac app (home window, session window, settings) |
| `Mobile/` | iPhone and iPad app (controller only) |
| `Packages/BridgeCore/` | Everything else: input protocol, signaling client, WebRTC session, screen capture, input injection |
| `server/` | Signaling server (Node 24, TypeScript, `ws`) |

## Build

Requires Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Node 24+ and pnpm.

```sh
xcodegen generate
xcodebuild -project MacBridge.xcodeproj -scheme MacBridge -derivedDataPath build build
open build/Build/Products/Debug/MacBridge.app
```

Builds are signed with a development identity (`DEVELOPMENT_TEAM` in `project.yml`). macOS ties the Screen Recording and Accessibility grants to the signature, so do not switch to ad-hoc signing.

## Set up

1. **Server.** Follow [docs/server-setup.md](docs/server-setup.md) to run the signaling service and relay on a machine with a public IP. For a quick test on one network, run it without Docker:

   ```sh
   cd server && pnpm install && ALLOW_NO_TOKEN=1 pnpm start
   ```

2. **Both Macs.** Copy the app over (`scripts/package.sh` makes `dist/MacBridge-<version>.zip`). In **Settings (⌘,) → Connection** enter the server (`wss://bridge.example.com`, or `ws://<ip>:8787` for the quick test) and the access token, then **Go online**.
3. **The Mac to be controlled.** In the main window turn on **Allow control**. In **Settings → Security** allow Screen Recording and Accessibility, then reopen the app. In **Settings → General** turn on **Open MacBridge at login**. Back in the main window click **Show pairing code**.
4. **The Mac you control from.** Type the code into **Connect to a Mac** and click **Pair**. The Mac appears as a tile; click it to connect.

Pairing is one-way: the Mac that showed the code can be controlled by the Mac that typed it. Repeat the other way round if you want both.

## The main window

- **Left:** this Mac's name and address, whether it is online, the **Allow control** switch and the pairing code.
- **Connect to a Mac:** type a paired Mac's name or address and press Return, or type a pairing code to add a Mac.
- **Tiles:** one per Mac you can control, with a picture from the last session, a dot (green online, grey offline) and when you last connected. Right-click to rename, mark as favourite or forget. Favourites come first.
- The menu bar icon has **Connect to** with the same Macs.

## In a session

- Mouse, keyboard and scroll go to the other Mac while its screen has focus, including ⌘ shortcuts.
- The clipboards stay the same: text copied on either Mac can be pasted on the other. Text only, up to 100 KB; copies a password manager marks as private are not sent.
- **Toolbar:**
  - *Name and connection* (click for details): direct or relayed, round trip, picture size, frame rate, bit rate, packets lost.
  - *Display*: choose which of the other Mac's displays to show.
  - *View*: Fit to Window, Fill Window (may cut the edges) or Actual Size.
  - *Quality*: Sharp, Balanced or Light.
  - *Actions*: previous and next desktop, Mission Control, Spotlight, switch app, send clipboard, lock screen.
  - *Full Screen*: move the pointer to the top edge to get the toolbar back.
  - *Disconnect*.
- Control-← and Control-→ (switch desktop), Control-↑ and ⌘Space go to the other Mac while the session window is in front, if this Mac allows MacBridge under Accessibility. Without that, use the Actions menu.
- Trackpad swipes between desktops and ⌘Tab stay on this Mac.
- If the session drops, the window offers **Reconnect**.

## On the Mac being controlled

- A small panel in the top right corner says who is in control and for how long, with **End**. The menu bar icon turns red.
- **With the lid closed** (Settings → Security, laptops only): *Sleep as usual*, *Stay reachable on the power adapter*, or *Always stay reachable*. It applies while Allow control is on and the Mac is online. The other Mac sees a virtual display, since the built-in screen is off. Staying awake needs [LidAwake](https://github.com/habibtalib/lidawake) installed: macOS only lets an administrator switch off lid-close sleep, and LidAwake holds that permission. Its battery and heat limits still apply. MacBridge turns it off again when control is switched off, the Mac goes offline or the app quits, unless you had turned LidAwake on yourself.
- **Ask first** (Settings → Security, per Mac): that Mac must be accepted on this Mac before it can connect. No answer in 30 seconds declines. Leave it off for a Mac nobody sits at.

## iPhone and iPad

`MacBridgeMobile` controls a Mac from an iPhone or iPad. It cannot be controlled itself: iOS does not allow it.

```sh
xcodegen generate
open MacBridge.xcodeproj      # choose the MacBridgeMobile scheme and your device, then Run
```

- **Set up:** in Settings (gear) enter the same server as your Macs and go online. If the server is on a private network such as Tailscale, the device has to be on it too.
- **Add a Mac:** on the Mac click **Show pairing code**, then scan its QR code with the scan button, or type the code and tap **Pair**.
- **Pointer:** two modes, switched from the bar at the top.
  - *Touch* (default on iPad): tap where you want to click, long press for a right click, drag to drag.
  - *Trackpad* (default on iPhone): drag to move the pointer, tap to click, tap then touch and drag to drag.
  - In both: two-finger tap is a right click, two-finger drag scrolls, pinch zooms the picture. While zoomed in, two fingers move the picture instead of scrolling.
- **Keyboard:** the keyboard button opens the on-screen keyboard with a bar for ⌘ ⌥ ⌃ ⇧ (held for the next key), Esc, Tab, arrows and common shortcuts. A hardware keyboard works as on a Mac. On-screen typing assumes a US keyboard layout on the Mac; characters without a key are pasted.
- **iPad with a mouse or trackpad:** the pointer, right click and scrolling go to the Mac.
- **More menu:** desktops, Mission Control, Spotlight, switch app, lock, quality, connection details, and the clipboard: *Send Clipboard to Mac* and *Get Mac's Clipboard* (manual, because iOS asks for permission on every automatic read).
- The session ends when the app goes to the background. Coming back offers to reconnect.

## Limits

- After a restart the controlled Mac is reachable only once someone has logged in. Use automatic login if it must come back unattended.
- It stays awake while control is allowed. A closed laptop sleeps unless *With the lid closed* is set (see above).
- No file transfer or audio.

## Security

Each install has an Ed25519 key in the keychain; its device ID is derived from the key. The server checks the access token and that a device holds its key, and nothing more. A session starts only when a paired device sends a signed, fresh request, and both sides sign the certificate fingerprints of the encrypted connection, so the server cannot read, alter or start a session. See the end of [docs/server-setup.md](docs/server-setup.md) for what a compromised server could still do.

## Tests

```sh
cd Packages/BridgeCore && swift test   # protocol, mapping, WebRTC loopback, client ↔ real server
cd server && pnpm test && pnpm typecheck
```

The WebRTC loopback test runs a host and a controller in one process and checks hardware H.264 video and both input channels end to end. The client ↔ server tests need `server/node_modules`.
