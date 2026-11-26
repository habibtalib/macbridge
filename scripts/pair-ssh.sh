#!/bin/bash
# Pairs two Macs that already run MacBridge, without the on-screen code, so that
# CONTROLLER can control HOST. Each is `user@host` for SSH, or `local` for this Mac.
#
#   scripts/pair-ssh.sh <controller> <host>
#   scripts/pair-ssh.sh me@macbook-air local             # the Air can control this Mac
#
# Being able to write both users' settings already proves you own both Macs.
# MacBridge is restarted on both.
set -euo pipefail
domain=com.habibtalib.macbridge
on() { # where command
  if [[ $1 == local ]]; then bash -c "$2"; else ssh -o BatchMode=yes "$1" "$2"; fi
}
key() { on "$1" "defaults read $domain publicKey"; }
name() { on "$1" "defaults read $domain deviceName 2>/dev/null || scutil --get ComputerName"; }
list() { on "$1" "defaults export $domain - | plutil -extract pairedDevices raw -o - - 2>/dev/null | base64 -d 2>/dev/null | xxd -p | tr -d '\n'" || true; }
app() { on "$1" 'ls -d /Applications/MacBridge.app 2>/dev/null || mdfind "kMDItemCFBundleIdentifier == com.habibtalib.macbridge" | grep -v /dist/ | head -1'; }
entry() { # existing-hex publicKey name mayControlThisMac thisMacMayControl
  python3 - "$@" <<'PY'
import sys, json, base64, hashlib, binascii
existing, key, name, may_control, this_may = sys.argv[1:6]
devices = json.loads(binascii.unhexlify(existing)) if existing else []
raw = base64.b64decode(key)
assert len(raw) == 32, "public key must be 32 bytes"
device_id = base64.b32encode(hashlib.sha256(raw).digest()[:10]).decode().lower()
old = next((d for d in devices if d["id"] == device_id), {})
devices = [d for d in devices if d["id"] != device_id] + [{
    "id": device_id, "publicKey": key, "name": name,
    "mayControlThisMac": old.get("mayControlThisMac", False) or may_control == "1",
    "thisMacMayControl": old.get("thisMacMayControl", False) or this_may == "1",
}]
print(binascii.hexlify(json.dumps(devices).encode()).decode())
PY
}
controller=$1 host=$2
ckey=$(key "$controller") hkey=$(key "$host")
cname=$(name "$controller") hname=$(name "$host")
capp=$(app "$controller") happ=$(app "$host")
on "$controller" 'pkill -x MacBridge' || true
on "$host" 'pkill -x MacBridge' || true
sleep 1
on "$controller" "defaults write $domain pairedDevices -data $(entry "$(list "$controller")" "$hkey" "$hname" 0 1)"
on "$host" "defaults write $domain pairedDevices -data $(entry "$(list "$host")" "$ckey" "$cname" 1 0)"
on "$controller" "open -g '$capp'"
on "$host" "open -g '$happ'"
echo "linked: $cname can control $hname"
