#!/bin/zsh
# Runs kveikur-lyrics under launchd, detached from any terminal.
#   ./background.sh start [options…]   build if needed and start (options go to kveikur-lyrics)
#   ./background.sh status             last lines of the log
#   ./background.sh stop               stop; a later start continues where it left off
# The job isn't installed in LaunchAgents, so it doesn't come back after a reboot by itself.
set -e
cd "${0:A:h}"
LABEL=dev.kveikur.lyrics-batch
LOG=~/Library/Logs/Kveikur/lyrics-batch.log
PLIST=~/Library/Application\ Support/Kveikur/$LABEL.plist
BIN=$PWD/.build/release/kveikur-lyrics

case "${1:-status}" in
start)
    shift
    swift build -c release >/dev/null
    mkdir -p ~/Library/Logs/Kveikur
    launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
    args=""
    for a in "$@"; do args+="<string>$a</string>"; done
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/caffeinate</string><string>-i</string><string>$BIN</string>$args</array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Standard</string>
</dict></plist>
EOF
    launchctl bootstrap gui/$UID "$PLIST"
    echo "Started; log: $LOG"
    ;;
stop)
    launchctl bootout gui/$UID/$LABEL 2>/dev/null && echo "Stopped." || echo "Not running."
    ;;
status)
    if launchctl print gui/$UID/$LABEL 2>/dev/null | grep -q "state = running"; then echo "Running."; else echo "Not running."; fi
    tail -n 5 "$LOG" 2>/dev/null || true
    ;;
*)
    sed -n '2,6p' "$0"; exit 2 ;;
esac
