# MacBridge

Control one Mac from another, from anywhere. One app on both Macs; a small server you host introduces them, then screen and input travel directly between the two Macs over WebRTC.

Status: early; not yet tried between two Macs over the internet. Working name.

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app (home screen, session window) |
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

2. **Both Macs.** Copy the app over (`scripts/package.sh` makes `dist/MacBridge-<version>.zip`). Under **Connection** enter the server (`wss://bridge.example.com`, or `ws://<ip>:8787` for the quick test) and the access token, then **Go online**.
3. **The Mac to be controlled.** Turn on **Allow this Mac to be controlled**, allow Screen Recording and Accessibility, reopen the app, turn on **Open MacBridge at login**, then click **Show pairing code**.
4. **The Mac you control from.** Click **Add a Mac…**, type the code, then **Connect**.

Pairing is one-way: the Mac that showed the code can be controlled by the Mac that typed it. Repeat the other way round if you want both.

## In a session

- Mouse, keyboard and scroll go to the other Mac while its screen has focus, including ⌘ shortcuts.
- ⌘V pastes text from this Mac's clipboard on the other Mac. Copying from the other Mac back to this one is not implemented yet.
- Toolbar: quality (Sharp / Balanced / Light), next display, disconnect.
- ⌘Tab, ⌘Space and other shortcuts macOS handles before apps see them stay on this Mac.

## Limits

- After a restart the controlled Mac is reachable only once someone has logged in. Use automatic login if it must come back unattended.
- It stays awake while control is allowed, but a closed laptop lid on battery still sleeps.
- No file transfer or audio.

## Security

Each install has an Ed25519 key in the keychain; its device ID is derived from the key. The server checks the access token and that a device holds its key, and nothing more. A session starts only when a paired device sends a signed, fresh request, and both sides sign the certificate fingerprints of the encrypted connection, so the server cannot read, alter or start a session. See the end of [docs/server-setup.md](docs/server-setup.md) for what a compromised server could still do.

## Tests

```sh
cd Packages/BridgeCore && swift test   # protocol, mapping, WebRTC loopback, client ↔ real server
cd server && pnpm test && pnpm typecheck
```

The WebRTC loopback test runs a host and a controller in one process and checks hardware H.264 video and both input channels end to end. The client ↔ server tests need `server/node_modules`.
