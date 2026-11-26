# Changelog

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
