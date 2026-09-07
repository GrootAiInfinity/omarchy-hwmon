#!/usr/bin/env bash
# Install AND enable the hwmon widget: copies the files, adds the widget to the
# omarchy bar layout, and reloads the shell. Idempotent.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${OMARCHY_CONFIG:-$HOME/.config/omarchy}"
SHELL_JSON="$CFG/shell.json"
ID="hwmon"

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

install -Dm644 "$SRC/bar/modules/$ID.qml" "$CFG/bar/modules/$ID.qml"
install -Dm755 "$SRC/bar/scripts/$ID.sh" "$CFG/bar/scripts/$ID.sh"
# point the widget at this machine's $HOME
sed -i "s#/home/groot/#$HOME/#g" "$CFG/bar/modules/$ID.qml"

cp "$SHELL_JSON" "$SHELL_JSON.bak.$(date +%s)"
tmp="$(mktemp)"
jq --arg id "$ID" '
  ({id:$id, type:"qml"}) as $entry
  | if (.bar.layout | type) == "object"
    then .bar.layout.right = ((.bar.layout.right // [])
         | if any(.[]?; .id == $id) then . else . + [$entry] end)
    else .bar.layout = ((.bar.layout // [])
         | if any(.[]?; .id == $id) then . else . + [$entry] end)
    end
' "$SHELL_JSON" > "$tmp" && mv "$tmp" "$SHELL_JSON"

omarchy restart shell 2>/dev/null || true
echo "hwmon installed and enabled. If the bar didn't refresh: omarchy restart shell"
