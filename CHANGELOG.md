# Changelog

## Unreleased

### Improved
- iPhone, iPad and Vision Pro: where the camera cannot scan codes (Vision Pro), the first-run steps say to type the pairing code instead of scanning it.

## 0.1.3 — 2026-11-27

### Added
- Local network: paired devices on the same network find each other with Bonjour and connect without the server, for example with Tailscale off. Both sides prove their paired key before anything is exchanged; setup messages go straight to the device when it is on the network and through the server otherwise. Pairing still needs the server. The status reads "Local network only" when only the local network is reachable.

### Fixed
- "Always relay through the server" with a server that has no TURN relay left a dark screen: the call now fails at once and says why, and a Mac being controlled with that setting connects directly instead.

## 0.1.2 — 2026-11-27

### Fixed
- Mac: the paired Mac tiles were not drawn when the main window opened (only after resizing it or switching the filter). Present since 0.1.0 on some systems.

## 0.1.1 — 2026-11-26

An audit release: security, stability and connection fixes. Mac and server should both be updated.

### Security
- A pairing link (QR code or `macbridge://` link) that names another server now asks before switching, and the access token is never sent to a server it was not entered for. Tokens are kept per server.
- Revoking a Mac also declines its pending request, and the host checks again before a session starts.
- Clipboard text over 100 KB is refused on arrival; data channels opened by the other side are ignored.
- Server: per-connection rate limit, slow-reader cutoff, total and per-IP connection caps checked before the WebSocket opens (HTTP 503), `TRUST_PROXY` / `TRUST_PROXY_HOPS` for counting clients behind a proxy, and unknown message types answered instead of closing the connection. Fixed a crash when a refused client reset its connection.
- coturn refuses relaying to IPv6 private, loopback and link-local ranges and to the server's own address, and runs without its admin CLI.

### Fixed
- Screen capture no longer keeps running after a session that ended while capture was starting, and fast quality or display changes no longer leave a second capture running.
- No more stuck keys or modifiers: input arriving after a session ends is dropped, the controller releases held keys when its window loses focus, and ⌘-shortcut key-ups are sent.
- Pasting with ⌘V after sending the clipboard now pastes the new text.
- Unplugging the shown display or closing the lid mid-session moves to another display (or a virtual one) instead of ending the session; a display that keeps failing ends it after three tries.
- LidAwake: turning it on yourself is respected again (the pmset check always read "off").
- The saved quality is applied when a session starts; on iPhone and iPad, changes during a session stay with that session.
- Memory leaks of finished sessions and old server connections.

### Improved
- Connections recover by themselves: keepalive pings, reconnect on network change and wake, a shown pairing code survives a reconnect.
- A call that gets no answer fails after 45 seconds with a reason; a Mac that refuses says why (not allowed, clocks too far apart, no Screen Recording permission).
- A second copy of MacBridge with the same identity no longer fights the first: the older one stops and says so.
- Mac: closing the window during a session asks first; the menu bar shows the session with Disconnect; a call waiting for the server is shown and can be cancelled.
- iPhone and iPad: the screen stays on during a session; the app stays offline after you go offline on purpose; the camera-denied case is explained.
- Server and access token in Settings are saved when you finish editing, not on every keystroke.
- Device tiles keep their order while online status updates; accessibility labels for icon buttons and the key bar.
- The stats log is capped at 5 MB and no longer records IP addresses.

## 0.1.0 — 2026-11-26

First public release. macOS 15 or later, Apple silicon.

### Mac app
- Control one Mac from another over WebRTC: hardware H.264 video, mouse, keyboard (including ⌘ shortcuts) and scroll. Retina-sized screens supported.
- Pairing by one-time code or QR code. Each install has an Ed25519 key in the keychain; sessions start only from a paired device with a signed, fresh request, and both sides sign the connection fingerprints, so the server cannot read, alter or start a session.
- Home window: this Mac's name and address, online state, **Allow control**, pairing code, a connect field, and one tile per paired Mac with a picture from the last session, online dot and last use. Rename, favourite or forget a Mac; favourites first, then online Macs. Filter by online, refresh.
- Session window: display picker, Fit / Fill / Actual Size, quality presets (Sharp, Balanced, Light), actions (desktops, Mission Control, Spotlight, switch app, send clipboard, lock screen), connection details, full screen, reconnect, save screenshot.
- Two-way text clipboard (up to 100 KB; private password-manager copies are not sent).
- Control-arrows and ⌘Space go to the other Mac while the session window is in front.
- Controlled Mac: panel showing who is in control with **End**, red menu bar icon, optional **Ask first** per Mac, virtual display when there is no screen, open at login, stays awake while control is allowed.
- Stay reachable with the lid closed through [LidAwake](https://github.com/habibtalib/lidawake): off, on the power adapter, or always.
- Menu bar: connect to a Mac, allow control, copy this Mac's address, show pairing code.

### iPhone and iPad (build from source)
- Controller app: pairing by code or QR (the QR also carries the server), touch and trackpad pointer modes, pinch zoom, on-screen keyboard with a modifier key bar, hardware keyboard and pointer, displays, shortcuts, manual clipboard both ways, default pointer and quality in Settings.

### Server
- Node 24 signaling server with access token, key login and paired-device checks; Docker Compose deployment with a coturn relay. See `docs/server-setup.md`.

### Known limits
- The release app is signed with a development certificate, not notarised: see "Install" in the README.
- No file transfer or audio. After a restart the controlled Mac is reachable only after someone logs in.
