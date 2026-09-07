#!/usr/bin/env bash
# Install the hwmon bar widget into ~/.config/omarchy.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${OMARCHY_CONFIG:-$HOME/.config/omarchy}"

install -Dm644 "$SRC/bar/modules/hwmon.qml" "$DEST/bar/modules/hwmon.qml"
install -Dm755 "$SRC/bar/scripts/hwmon.sh" "$DEST/bar/scripts/hwmon.sh"

echo "Installed:"
echo "  $DEST/bar/modules/hwmon.qml"
echo "  $DEST/bar/scripts/hwmon.sh"
echo
echo "Next: add  { \"id\": \"hwmon\", \"type\": \"qml\" }  to bar.layout in"
echo "  $DEST/shell.json"
echo "then run:  omarchy restart shell"

if [ "$USER" != "groot" ]; then
  echo
  echo "NOTE: your username is '$USER', not 'groot'. Edit the 'script' and"
  echo "'stateFile' properties near the top of hwmon.qml to match your \$HOME."
fi
