#!/usr/bin/env bash
# Usage: ROKU_DEV_PASS=... tools/deploy.sh <app-dir> [roku-ip]
# Zips the app dir and sideloads it via the Roku developer installer.
# Reversible: tools/deploy.sh --delete removes the dev channel.
set -euo pipefail
ROKU_IP="${2:-${ROKU_IP:-192.168.1.16}}"
: "${ROKU_DEV_PASS:?set ROKU_DEV_PASS}"
if [[ "${1:-}" == "--delete" ]]; then
  curl -sS --digest -u "rokudev:$ROKU_DEV_PASS" -F mysubmit=Delete -F archive= "http://$ROKU_IP/plugin_install" | grep -oE "Roku\.Message[^)]*\)" | head -5 || true
  exit 0
fi
APP="${1:?app dir}"
OUT="$(mktemp -d)/app.zip"
(cd "$APP" && zip -qr -9 "$OUT" manifest source components $( [ -d media ] && echo media ) $( [ -d images ] && echo images ) $( [ -d assets ] && echo assets ))
echo "zip: $(stat -c %s "$OUT") bytes"
curl -sS --digest -u "rokudev:$ROKU_DEV_PASS" -F mysubmit=Install -F "archive=@$OUT" "http://$ROKU_IP/plugin_install" \
  | grep -oE "(Install Success|Identical to previous version|Install Failure[^<]*|Compilation Failed[^<]*|Roku\.Message\.[a-z]+\([^)]*\)[^;]*)" | head -10
