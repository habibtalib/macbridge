# MacBridge

Control one Mac from another, from anywhere. One app on both Macs; a small server you host introduces them, then screen and input travel directly between the two Macs over WebRTC.

Status: early. Working name.

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

## Try it on a local network

1. Start the signaling server on either Mac:

   ```sh
   cd server && pnpm install && pnpm start
   ```

2. On both Macs, open MacBridge and under **Connection** set **Server** to `ws://<ip-of-the-server-mac>:8787`, give each Mac a different device name, and click **Go online**.
3. On the Mac to be controlled, turn on **Allow this Mac to be controlled** and allow Screen Recording and Accessibility when asked (quit and reopen the app after granting Screen Recording).
4. On the other Mac, type the first Mac's device name under **Control another Mac** and click **Connect**.

## Tests

```sh
cd Packages/BridgeCore && swift test   # protocol, mapping, WebRTC loopback, client ↔ real server
cd server && pnpm test && pnpm typecheck
```

The WebRTC loopback test runs a host and a controller in one process and checks hardware H.264 video and both input channels end to end. The client ↔ server tests need `server/node_modules`.
