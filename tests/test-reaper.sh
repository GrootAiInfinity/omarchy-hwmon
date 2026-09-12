#!/bin/bash
# `hwmon.sh reap` is what the widget falls back on when a sample outlives its
# deadline and ignores SIGTERM. It decides from /proc alone, so these check both
# halves: that it tears down what is really ours, and that it refuses - without
# signalling anything - when the pid is not.
set -u
. "$(dirname "$0")/lib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "== reaper"

read -r LEADER CHILD <<<"$(wedged_sample "$TMP/pids")"
kill -TERM "$LEADER" 2>/dev/null; sleep 0.3
is "SIGTERM alone does not stop it"        "$(alive "$LEADER")" yes
is "nor its helper"                        "$(alive "$CHILD")"  yes
setsid "$HWMON" reap "$LEADER" 0; is "reap succeeds" "$?" 0
is "the sample is gone"                    "$(alive "$LEADER")" no
is "the helper under it is gone too"       "$(alive "$CHILD")"  no

# A helper that outlives the sample it belonged to still holds the pipe. The
# leader is gone by then, so the group is swept on its own.
read -r LEADER2 CHILD2 <<<"$(wedged_sample "$TMP/pids2" 0)"
kill -TERM "$LEADER2" 2>/dev/null; sleep 0.5
is "the sample itself exited"              "$(alive "$LEADER2")" no
is "its helper did not"                    "$(alive "$CHILD2")"  yes
setsid "$HWMON" reap "$LEADER2" 0 >/dev/null 2>&1
is "the orphaned helper is swept"          "$(alive "$CHILD2")"  no

setsid sleep 300 & OTHER=$!; disown; sleep 0.3   # disowned: no job-control noise
setsid "$HWMON" reap "$OTHER" 0 2>/dev/null; is "a pid that is not ours is refused" "$?" 1
is "and is left running"                   "$(alive "$OTHER")" yes
kill -9 "$OTHER" 2>/dev/null

read -r YOUNG _ <<<"$(wedged_sample "$TMP/pids3")"
setsid "$HWMON" reap "$YOUNG" 600 2>/dev/null
is "one of ours younger than the deadline is refused" "$?" 1
is "and is left running"                   "$(alive "$YOUNG")" yes
setsid "$HWMON" reap "$YOUNG" 0 >/dev/null 2>&1

FREE=$(( $(cat /proc/sys/kernel/pid_max) - 2 ))
while kill -0 "$FREE" 2>/dev/null; do FREE=$((FREE - 1)); done
setsid "$HWMON" reap "$FREE" 10 2>/dev/null; is "an empty group is a no-op" "$?" 0

setsid /bin/bash -c 'exec "$0" reap $$ 0' "$HWMON" 2>/dev/null
is "it refuses its own process group" "$?" 1

setsid "$HWMON" reap "" 0 2>/dev/null;      is "no pid is rejected"      "$?" 2
setsid "$HWMON" reap notanumber 0 2>/dev/null; is "a non-pid is rejected" "$?" 2
setsid "$HWMON" reap 1 0 2>/dev/null;       is "init is never a target"  "$?" 2

summary
