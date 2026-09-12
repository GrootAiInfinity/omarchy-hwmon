#!/bin/bash
# The widget half of the deadline: a sample that ignores SIGTERM has to be taken
# apart by the escalation, and the shell it runs in must be left alone. This
# drives the real Guarded component out of hwmon.qml under a real Quickshell, so
# it only runs where one is installed.
set -u
. "$(dirname "$0")/lib.sh"
command -v qs >/dev/null 2>&1 || { echo "== widget: skipped (no quickshell)"; exit 0; }
echo "== widget"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
QML=$(dirname "$0")/../hwmon.qml

# Lift launch(), the Guarded component and reap() out of the widget verbatim, so
# what is exercised here is the shipped code and not a copy of it.
python3 - "$QML" "$TMP" "$HWMON" <<'PY'
import sys
qml, tmp, hwmon = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(qml).read()
def block(start, end):
    i = src.index(start)
    return src[i:src.index(end, i)]
parts = (block('  function launch(argv) {', '  property var stats:'),
         block('  component Guarded: QtObject {', '  // The deadline doubles'),
         block('  property var reapQueue: []', '  // ====='))
open(tmp + '/probe.qml', 'w').write('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: root
  readonly property string script: "%s"
%s
  Guarded { id: statsRun; deadlineMs: 2000 }
%s
  Component.onCompleted: statsRun.start(["/bin/bash", "-c",
    'trap "" TERM INT HUP; ( trap "" TERM INT HUP; exec sleep 600 ) & printf "%%s %%s\\\\n" "$$" "$!" > "%s/pids"; while :; do sleep 1; done',
    root.script])
}
''' % (hwmon, '\n'.join(p.rstrip() for p in parts), '', tmp))
PY

qs -p "$TMP/probe.qml" >"$TMP/qs.log" 2>&1 & QS=$!
waited=0
while [ ! -s "$TMP/pids" ] && [ "$waited" -lt 200 ]; do sleep 0.05; waited=$((waited + 1)); done
read -r LEADER CHILD <"$TMP/pids" 2>/dev/null || { bad "the probe never started"; summary; exit 1; }

# 2s deadline, 3s before the escalation, then TERM, settle and KILL.
waited=0
while { [ "$(alive "$LEADER")" = yes ] || [ "$(alive "$CHILD")" = yes ]; } && [ "$waited" -lt 200 ]; do
  sleep 0.1; waited=$((waited + 1))
done
is "the wedged sample is gone"        "$(alive "$LEADER")" no
is "so is the helper under it"        "$(alive "$CHILD")"  no
is "the shell itself is untouched"    "$(alive "$QS")"     yes
kill "$QS" 2>/dev/null; kill -9 "$LEADER" "$CHILD" 2>/dev/null
summary
