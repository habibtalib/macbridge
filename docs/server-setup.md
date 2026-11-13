# Server setup

The server side is two containers on a machine with a public IP:

- **signaling**: introduces the two Macs. Sees who is online and forwards encrypted-or-signed setup messages. Never sees the screen or input.
- **coturn**: relays the session only when the two Macs cannot reach each other directly.

## 1. DNS and firewall

Point two names at the server, for example `bridge.example.com` (signaling) and `turn.example.com` (relay). They can be the same host.

Open in the firewall:

| Port | Protocol | For |
|---|---|---|
| 443 | TCP | signaling, through your reverse proxy |
| 3478 | UDP and TCP | STUN/TURN |
| 49160–49200 | UDP | relayed media |

## 2. Configure

```sh
cd server
cp .env.example .env
```

Fill in `.env`:

```sh
openssl rand -base64 32   # ACCESS_TOKEN
```

```sh
openssl rand -hex 32      # TURN_SECRET
```

Set `TURN_HOST`, `PUBLIC_IP`, `STUN_URLS` and `TURN_URLS` to your relay hostname and the server's public IPv4 address.

## 3. Start

```sh
docker compose up -d --build
```

```sh
docker compose logs -f
```

## 4. TLS

Signaling listens on `127.0.0.1:8787`. Forward `wss://bridge.example.com` to it from your reverse proxy with WebSocket upgrade enabled. Caddy example:

```
bridge.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

## 5. On each Mac

In MacBridge under **Connection**: Server `wss://bridge.example.com`, the access token, then **Go online**.

## Check the relay

On both Macs turn on **Always relay through the server**, reconnect, and start a session. If it works, coturn and its credentials are correct. Turn the setting off again afterwards: relayed sessions add delay and use the server's bandwidth.

## What a compromised server could do

It could refuse service, see which device IDs are online and when, and see the IP addresses of the Macs. It could not view or control a Mac: sessions are only accepted between paired devices, pairing is protected by the code shown on screen, and the server holds no keys.
