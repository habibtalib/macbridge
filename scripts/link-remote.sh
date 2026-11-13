#!/bin/bash
# Installs MacBridge on another Mac you can SSH into, points both Macs at the
# same signaling server, and pairs them so THIS Mac can control THAT one.
#
#   scripts/link-remote.sh <user@host> <server-url>
#   scripts/link-remote.sh habibtalib@habibs-mac-mini ws://100.77.252.76:8787
#
# Pairing here skips the on-screen code: being able to write both users'
# settings already proves you own both Macs. Screen Recording and
# Accessibility on the other Mac still have to be allowed by hand.
set -euo pipefail
cd "$(dirname "$0")/.."
remote=$1 server=$2
domain=com.habibtalib.macbridge
rssh() { ssh -o BatchMode=yes "$remote" "$@"; }

zip=$(scripts/package.sh | tail -1)
local_app=$PWD/build/Build/Products/Release/MacBridge.app

echo "== install on $remote"
scp -q "$zip" "$remote:/tmp/MacBridge.zip"
rssh 'pkill -x MacBridge; rm -rf /Applications/MacBridge.app && ditto -x -k /tmp/MacBridge.zip /Applications && rm /tmp/MacBridge.zip && codesign --verify --deep --strict /Applications/MacBridge.app && echo installed'

echo "== start both once so each creates its key"
pkill -x MacBridge || true
defaults write $domain serverURL "$server"
rssh "defaults write $domain serverURL '$server'; defaults write $domain allowsControl -bool true; open -g /Applications/MacBridge.app"
open -g "$local_app"
for _ in $(seq 20); do
  here=$(defaults read $domain publicKey 2>/dev/null || true)
  there=$(rssh "defaults read $domain publicKey 2>/dev/null" || true)
  [[ -n "$here" && -n "$there" ]] && break
  sleep 1
done
[[ -n "$here" && -n "$there" ]] || { echo "a Mac did not create its key (is someone logged in on $remote?)"; exit 1; }
here_name=$(defaults read $domain deviceName 2>/dev/null || scutil --get ComputerName)
there_name=$(rssh "defaults read $domain deviceName 2>/dev/null || scutil --get ComputerName")

echo "== pair"
pkill -x MacBridge || true
rssh 'pkill -x MacBridge' || true
sleep 1
# Merges one device into the saved list (hex-encoded JSON, as the app stores it).
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
read_list_local() { defaults export $domain - | plutil -extract pairedDevices raw -o - - 2>/dev/null | base64 -d 2>/dev/null | xxd -p | tr -d '\n' || true; }
read_list_remote() { rssh "defaults export $domain - | plutil -extract pairedDevices raw -o - - 2>/dev/null | base64 -d 2>/dev/null | xxd -p | tr -d '\n'" || true; }

defaults write $domain pairedDevices -data "$(entry "$(read_list_local)" "$there" "$there_name" 0 1)"
rssh "defaults write $domain pairedDevices -data $(entry "$(read_list_remote)" "$here" "$here_name" 1 0)"

echo "== start"
rssh 'open -g /Applications/MacBridge.app'
open "$local_app"
echo "linked: $here_name can control $there_name"
