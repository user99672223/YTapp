#!/bin/bash
# install.sh RUN_ID — download the CI artifact App-unsigned.ipa of GitHub Actions run RUN_ID and
# install it on the Apple TV through atvloadly's MCP API (updates the existing Tube install).
#
# Tube is closed first: tvOS holds an install for ~10 minutes while the app runs. The IPA is
# served to the atvloadly container over HTTP on the container network's gateway only, and the
# script checks that atvloadly stored exactly this IPA (it keeps it for the weekly re-sign).
# With one device and one Apple account in atvloadly they are picked automatically; otherwise
# set ATVLOADLY_DEVICE_ID / ATVLOADLY_ACCOUNT_ID.
set -euo pipefail
RUN=$1
HERE=$(dirname "$(readlink -f "$0")")
REPO=${GH_REPO:-$(cd "$HERE/../.." && gh repo view --json nameWithOwner -q .nameWithOwner)}
CONTAINER=${ATVLOADLY_CONTAINER:-atvloadly}
DIR=$HOME/tvtools/ipa/$RUN
mkdir -p "$DIR"
[ -f "$DIR/App-unsigned.ipa" ] || gh run download "$RUN" -R "$REPO" -n App-unsigned-ipa -D "$DIR" >/dev/null
IPA=$DIR/App-unsigned.ipa
SIZE=$(stat -c %s "$IPA")
echo "ipa $IPA ($SIZE bytes)" >&2
M="$HERE/mcp.sh"
tool() { "$M" tools/call "{\"name\":\"$1\",\"arguments\":${2:-{\}}}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["content"][0]["text"])'; }
DEVICE=${ATVLOADLY_DEVICE_ID:-$(tool get_device_list | python3 -c 'import json,sys; d=json.load(sys.stdin)["available_devices"]; assert len(d)==1, "several devices: set ATVLOADLY_DEVICE_ID"; print(d[0]["id"])')}
ACCOUNT=${ATVLOADLY_ACCOUNT_ID:-$(tool get_account_list | python3 -c 'import json,sys; d=json.load(sys.stdin)["available_accounts"]; assert len(d)==1, "several accounts: set ATVLOADLY_ACCOUNT_ID"; print(d[0]["account_id"])')}
APP_ID=$(tool get_app_list | python3 -c 'import json,sys; print(next((str(a["id"]) for a in json.load(sys.stdin)["items"] if a["bundle_identifier"]=="com.local.tube"), ""))')
"$HERE/tv" kill >/dev/null 2>&1 || true
GATEWAY=$(docker inspect "$CONTAINER" --format '{{range .NetworkSettings.Networks}}{{.Gateway}} {{end}}' | awk '{print $1}')
PORT=$(( 8800 + RANDOM % 100 ))
python3 -m http.server $PORT --bind "$GATEWAY" --directory "$DIR" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1
docker exec "$CONTAINER" sh -c "curl -sI http://$GATEWAY:$PORT/App-unsigned.ipa | grep -i content-length" | grep -q "$SIZE" || { echo "container cannot fetch the IPA" >&2; exit 1; }
T0=$(date -u +%s)
tool install_app "{\"ipa_url\":\"http://$GATEWAY:$PORT/App-unsigned.ipa\",\"device_id\":\"$DEVICE\",\"account_id\":\"$ACCOUNT\"}" | grep -q queued || { echo "install not queued" >&2; exit 1; }
for i in $(seq 1 180); do
  sleep 5
  tool get_install_status | grep -q '"install_in_progress":false' && break
done
docker exec "$CONTAINER" tail -2 /data/app.log | cut -c1-160
if [ -n "$APP_ID" ]; then
  STORED=$(docker exec "$CONTAINER" stat -c %s "/data/ipa/$APP_ID/app.ipa")
  echo "elapsed $(( $(date -u +%s) - T0 ))s; atvloadly stored $STORED bytes (expected $SIZE)"
  [ "$STORED" = "$SIZE" ] || { echo "WRONG IPA INSTALLED" >&2; exit 1; }
else
  echo "elapsed $(( $(date -u +%s) - T0 ))s (first install: nothing to compare)"
fi
