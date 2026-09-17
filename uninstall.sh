#!/usr/bin/env bash
# t2-mac-dsp — uninstaller
#
# Removes the user-level config and restarts the audio stack,
# returning to the system's default pass-through output.
# Touches no system files.

set -euo pipefail

CONF="$HOME/.config/pipewire/pipewire.conf.d/50-t2-dsp.conf"

echo "t2-mac-dsp uninstaller"
echo "──────────────────────"

if [ -f "$CONF" ]; then
    rm -f "$CONF"
    echo "Removed $CONF"
else
    echo "Config not present, nothing to remove"
fi

echo "Restarting audio stack..."
systemctl --user restart pipewire pipewire-pulse wireplumber
sleep 6

echo
echo "Current default output:"
wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -m1 'node.name' | sed 's/^/  /'
echo
echo "Done. Audio is back to pass-through (no DSP processing)."
