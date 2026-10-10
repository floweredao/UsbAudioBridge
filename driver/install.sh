#!/bin/bash
# Installs (or with -u removes) TabletAudio.driver and restarts coreaudiod. Needs sudo.
set -euo pipefail
cd "$(dirname "$0")"

DEST=/Library/Audio/Plug-Ins/HAL/TabletAudio.driver
if [ "${1:-}" = "-u" ]; then
  sudo rm -rf "$DEST"
else
  [ -d build/TabletAudio.driver ] || { echo "run driver/build.sh first" >&2; exit 1; }
  sudo rm -rf "$DEST"
  sudo cp -R build/TabletAudio.driver "$DEST"
  sudo chown -R root:wheel "$DEST"
fi
# launchctl kickstart is refused under SIP; launchd respawns coreaudiod after killall.
sudo killall coreaudiod
echo "done; audio devices reload in a few seconds"
