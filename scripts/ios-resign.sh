#!/bin/zsh
# Re-signs and reinstalls the iPhone beta before its free 7-day profile expires.
# Run by launchd every few hours (make ios-autosign); does nothing while the profile has more than $MARGIN_H hours left.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO="${0:A:h:h}"
BUNDLE="dev.kveikur.mobile"
MARGIN_H="${MARGIN_H:-48}"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
LOG_DIR="$HOME/Library/Logs/Kveikur"
mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/ios-resign.log" 2>&1

notify() { osascript -e "display notification \"$1\" with title \"Kveikur iPhone beta\"" >/dev/null 2>&1 }

# Profile file and its expiry (epoch seconds) for the app, newest first.
profile=""; expires=0
setopt nullglob
for f in "$PROFILES"/*; do
  plist=$(security cms -D -i "$f" 2>/dev/null) || continue
  id=$(plutil -extract Entitlements.application-identifier raw -o - - <<<"$plist" 2>/dev/null)
  [[ "$id" == *".$BUNDLE" ]] || continue
  exp=$(plutil -extract ExpirationDate raw -o - - <<<"$plist" 2>/dev/null)
  e=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$exp" +%s 2>/dev/null) || continue
  if (( e > expires )); then expires=$e; profile=$f; fi
done

now=$(date +%s)
left_h=$(( (expires - now) / 3600 ))
if [[ "${1:-}" != "--force" ]] && (( left_h > MARGIN_H )); then
  exit 0
fi

echo "=== $(date '+%F %T') profile has ${left_h}h left, re-signing"
cd "$REPO" || exit 1
device=$(make -s -f Makefile print-device 2>/dev/null)
if [[ -z "$device" ]]; then
  echo "iPhone not reachable"
  (( left_h < 12 )) && notify "Signature expires in ${left_h}h and the iPhone isn't reachable. Unlock it on the same Wi‑Fi."
  exit 1
fi

# A fresh build reuses a still-valid profile; dropping it makes Xcode issue a new 7-day one.
[[ -n "$profile" ]] && rm -f "$profile"
if make ios-device LAUNCH=0; then
  echo "ok"
  notify "Re-signed for another 7 days."
else
  echo "failed"
  notify "Re-signing failed; it will retry in a few hours. Log: ~/Library/Logs/Kveikur/ios-resign.log"
  exit 1
fi
