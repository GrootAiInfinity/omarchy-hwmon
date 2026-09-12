#!/bin/bash
# The backend's output contract, and the two habits the whole design rests on:
# nothing from outside is trusted into the JSON, and nothing is resolved through
# the caller's environment.
set -u
. "$(dirname "$0")/lib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "== backend"

out=$("$HWMON" stats)
is "stats is one line"            "$(printf '%s' "$out" | wc -l)" 0
is "stats is valid JSON"          "$(jq -e . >/dev/null 2>&1 <<<"$out"; echo $?)" 0
is "it has the keys the widget reads" \
   "$(jq -r '[has("cpu_pct"),has("mem_pct"),has("gpus"),has("host"),has("temp_c")]|all' <<<"$out")" true
is "light samples skip panel-only work" \
   "$(jq -r '[(.storage|length),(.top_cpu|length),(.fans|length)]|add' <<<"$out")" 0

full=$("$HWMON" stats --full)
is "--full is valid JSON"         "$(jq -e . >/dev/null 2>&1 <<<"$full"; echo $?)" 0
is "--full says so"               "$(jq -r .full <<<"$full")" true
is "--full lists processes"       "$(jq -r '.top_cpu|length > 0' <<<"$full")" true

# Round 1: a planted binary earlier in PATH must not be reachable. The widget
# launches this with an empty environment; running it by hand from a poisoned
# one has to be just as safe.
mkdir -p "$TMP/evil"
for tool in jq df ps awk uname lspci nvidia-smi stat timeout readlink getconf; do
  printf '#!/bin/sh\nprintf "PLANTED"\n' > "$TMP/evil/$tool"
  chmod +x "$TMP/evil/$tool"
done
poisoned=$(PATH="$TMP/evil:$PATH" BASH_ENV="$TMP/evil/rc" ENV="$TMP/evil/rc" "$HWMON" stats)
is "a poisoned PATH changes nothing" "$(jq -e . >/dev/null 2>&1 <<<"$poisoned"; echo $?)" 0
is "and no planted output reaches the JSON" \
   "$(grep -c PLANTED <<<"$poisoned")" 0
is "the readout is still real"    "$(jq -r '.cpu_model != null and .host.kernel != ""' <<<"$poisoned")" true

# A locale that formats decimals with a comma used to be enough to produce
# invalid JSON. Only meaningful where such a locale is actually generated.
comma_locale=$(locale -a 2>/dev/null | grep -iE '^(de_DE|fr_FR|pt_BR|es_ES)' | head -1)
if [ -n "$comma_locale" ]; then
  localized=$(LC_ALL="$comma_locale" LANG="$comma_locale" "$HWMON" stats)
  is "a comma-decimal locale still emits JSON" "$(jq -e . >/dev/null 2>&1 <<<"$localized"; echo $?)" 0
else
  printf '  skip a comma-decimal locale (none generated here)\n'
fi

# Process names are attacker-chosen text: any user can run a binary called a"b.
cp /bin/sleep "$TMP/a\"b\$(id) name" 2>/dev/null && "$TMP/a\"b\$(id) name" 30 &
HOSTILE=$!
sleep 0.3
hostile=$("$HWMON" stats --full)
is "a hostile process name cannot break the JSON" "$(jq -e . >/dev/null 2>&1 <<<"$hostile"; echo $?)" 0
is "and is carried as one string"  "$(jq -r '[.top_cpu[],.top_mem[]]|map(.name)|all(type=="string")' <<<"$hostile")" true
kill "$HOSTILE" 2>/dev/null

is "an unknown argument is refused"  "$("$HWMON" bogus >/dev/null 2>&1; echo $?)" 2
is "--help works"                    "$("$HWMON" --help >/dev/null 2>&1; echo $?)" 0
# The saved preference lives in the widget's shell.json entry, written by the
# shell. The backend itself must leave the filesystem alone.
mkdir -p "$TMP/home"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/home/state" "$HWMON" stats --full >/dev/null 2>&1
is "it creates no files of its own"  "$(find "$TMP/home" -mindepth 1 2>/dev/null | wc -l)" 0

summary
