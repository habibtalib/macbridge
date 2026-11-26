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

### Limits

The signaling service protects itself from a misbehaving or hostile client. Each limit is optional in `.env`; empty means the default.

| Variable | Default | What it does |
|---|---|---|
| `RATE_LIMIT_PER_SECOND` | 50 | Messages one connection may send per second, on average. Over the limit the connection gets `rate-limited` and is closed (code 4004). |
| `RATE_LIMIT_BURST` | 100 | Messages one connection may send at once before the average applies. |
| `MAX_BUFFERED_BYTES` | 1048576 | A device that reads too slowly is dropped once this much waits to be sent to it. |
| `MAX_CONNECTIONS` | 1000 | Connections in total. More are refused with HTTP 503 before the WebSocket opens, and the app retries later. |
| `MAX_CONNECTIONS_PER_IP` | 20 | Connections from one address. |
| `TRUST_PROXY` | 1 in `docker-compose.yml`, else off | `1` counts connections by the client address in `X-Forwarded-For`. Use it only when the service is reachable through your reverse proxy alone, as in `docker-compose.yml`. |
| `TRUST_PROXY_HOPS` | 1 | How many proxies append to `X-Forwarded-For`. The client is the entry this many places from the end; entries before it are whatever the client sent and are ignored. |

With `TRUST_PROXY=1` the reverse proxy **must** set or append `X-Forwarded-For` with the address it was reached from. Caddy does this by default; for nginx use `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`. A proxy that passes the header through unchanged lets any client name any address and dodge the per-address limit. Without the header, every client counts as the proxy's own address and shares one `MAX_CONNECTIONS_PER_IP` allowance.

A message type the server does not know gets `{"type":"error","code":"unsupported","messageType":"<type>"}` and the connection stays open.

coturn in `docker-compose.yml` refuses to relay to private, loopback and link-local addresses (IPv4 and IPv6) and to the server's own `PUBLIC_IP`, and its admin console is off (`--no-cli`).

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

What it could still do with the setup messages it forwards:

- **End sessions.** A `bye` (end of session, or "request declined") travels unsigned, so the server, or anyone who controls it, can forge one and end any session or decline any request. A forged reason ("not allowed", "clocks differ", "no screen permission") only changes the message shown for a request still waiting. That is a denial of service, the same as dropping messages, and gives no access.
- **Inject ICE candidates.** Candidates (network addresses to try) also travel unsigned. A forged candidate can make a Mac try to connect to an address the server picks, which reveals that the Mac is online and from where, or sends the connection attempt through a path the attacker controls. It cannot take over the session: the offer and answer are signed by the paired devices and carry the DTLS fingerprints, so the encrypted connection only completes with the real peer. A relayed path still only carries encrypted media and input.
- **Withhold or misreport presence.** It can say a Mac is offline when it is not.

Keep the access token secret and give each server its own: the apps keep one token per server and only send it to the server it was entered for. A pairing link that names another server asks before switching.
