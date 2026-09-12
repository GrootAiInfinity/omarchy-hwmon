# Shared helpers for the checks in this directory.
# Sourced, never run on its own.

HWMON=${HWMON:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hwmon.sh}
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
isnt() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1: got [$2], expected anything else"; fi; }

summary() {
  printf '%s: %d passed, %d failed\n' "${0##*/}" "$PASS" "$FAIL"
  [ "$FAIL" = 0 ]
}

alive() { kill -0 "$1" 2>/dev/null && printf yes || printf no; }

# NOTE: its stdout and stderr are closed off deliberately - the sample outlives
# this function, so a $( ) around the call would otherwise block waiting for a
# pipe that never reaches EOF.
#
# A process that looks like one of ours - the script's path is in its command
# line - which ignores SIGTERM and leaves a child doing the same. Prints
# "<leader> <child>". No fixture script: the real backend path is passed as $0
# so the reaper's identity check sees exactly what it would in the bar.
wedged_sample() {
  local out=$1 ignore_term=${2:-1}
  setsid /bin/bash -c '
    [ "$1" = 1 ] && trap "" TERM INT HUP
    ( trap "" TERM INT HUP; exec sleep 600 ) &
    printf "%s %s\n" "$$" "$!" > "$2"
    while :; do sleep 1; done
  ' "$HWMON" "$ignore_term" "$out" >/dev/null 2>&1 &
  local waited=0
  while [ ! -s "$out" ] && [ "$waited" -lt 100 ]; do sleep 0.05; waited=$((waited + 1)); done
  cat "$out"
}
