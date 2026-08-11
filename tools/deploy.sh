#!/bin/sh
# Copy PocketFlex onto the Onion SD card.
#
#   tools/deploy.sh [/Volumes/ONION]
#
# Deliberately conservative: it only ever writes inside App/PocketFlex, never
# touches anything else on the card, and never copies the local data/ dir
# (which holds a desktop-test auth token) onto the device.

set -e
CARD="${1:-/Volumes/ONION}"
here=$(cd -- "$(dirname "$0")/.." >/dev/null 2>&1 && pwd -P)
src="$here/App/PocketFlex"
dst="$CARD/App/PocketFlex"

[ -d "$CARD" ] || { echo "SD card not mounted at $CARD"; exit 1; }
[ -d "$CARD/App" ] || { echo "$CARD does not look like an Onion card (no App/)"; exit 1; }
[ -d "$src" ] || { echo "missing $src"; exit 1; }

echo "Installing to $dst"
mkdir -p "$dst/lib" "$dst/res"

cp "$src/config.json" "$dst/config.json"
cp "$src/launch.sh"   "$dst/launch.sh"
cp "$src/lib/"*.sh    "$dst/lib/"
cp "$src/res/cacert.pem" "$dst/res/cacert.pem"
# The boot splash. Two copies, one rotated 180 -- launch.sh picks by the same
# `flip` setting the video path uses, since both are asking the same question
# about how the panel is mounted. Both must ship: imgpop rotates 180 on its own,
# so which copy comes out upright depends on the unit, and the selection in
# launch.sh reads backwards on purpose. Don't "tidy" either of these away.
cp "$src/res/splash.png" "$src/res/splash180.png" "$dst/res/"
# The Apps-menu icon, which config.json points at by absolute path. The
# mark-only alternative ships too so switching is a one-line edit rather than a
# regeneration; tools/mkicon.py builds both from image_assets.
cp "$src/res/icon.png" "$src/res/icon-mark.png" "$dst/res/"

# Scripts must be executable; FAT32 carries the bit via the mount options, and
# Onion runs launch.sh directly.
chmod 755 "$dst/launch.sh" "$dst/lib/"*.sh 2>/dev/null || true

# Runtime state lives on the card so sign-in survives reboots, but we never
# seed it from the desktop. cache/ holds downloaded video and is never touched
# by an install -- reinstalling must not silently delete gigabytes.
mkdir -p "$dst/data" "$dst/cache"

echo "Syncing to disk..."
sync

echo
echo "Installed files:"
find "$dst" -type f -not -path "$dst/cache/*" | sed "s|$CARD/||" | sort
kept=$(find "$dst/cache" -name '*.mkv' 2>/dev/null | wc -l | tr -d ' ')
[ "$kept" -gt 0 ] && echo && echo "Left alone: $kept downloaded titles in cache/"
echo
echo "Done. Eject the card and look for PocketFlex in Onion's Apps menu."
