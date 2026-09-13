#!/bin/bash
# Hardware monitor backend for the Omarchy bar widget (hwmon.qml).
#
#   hwmon.sh stats          Lightweight sample: CPU, memory, load, temps, fans,
#                           AMD/Intel GPU, disks, network, battery, uptime.
#   hwmon.sh stats --full   Everything above plus NVIDIA GPU (nvidia-smi, which
#                           can wake the dGPU), physical storage devices and the
#                           top processes by CPU/RAM.
#   hwmon.sh reap PID AGE   Tear down a sample that outlived its deadline, after
#                           re-checking from /proc that PID is still the leader
#                           of a group of ours at least AGE seconds old.
#   hwmon.sh --help         Usage.
#
# Output is a single line of JSON on stdout. Missing metrics are emitted as
# null / empty arrays so the QML side can just check for them. Every value that
# reaches the JSON is either produced by jq (which escapes it) or passed through
# `num`, so no reading from /proc, /sys, `ps` or `df` can produce broken JSON.
#
# The script reads only kernel-provided files and runs only read-only tools. It
# asks for no elevated privileges, never touches the network, and writes no
# files at all: the widget's one saved preference is kept by the shell, in this
# widget's own entry in shell.json.
#
# The interpreter is an absolute path and PATH is replaced with root-owned
# system directories before any helper runs, so a binary planted earlier in the
# caller's PATH cannot stand in for jq, df, ps, nvidia-smi or lspci.
# The widget additionally launches this script with an empty environment.

set -u

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Parsing tool output is only deterministic in the C locale: another locale can
# translate df's header, or make awk/ps print "1,5" where JSON needs "1.5".
export LC_ALL=C

umask 077

SAMPLE_INTERVAL=0.35

# Nothing this script reads is supposed to be large, and every one of these
# producers is external. Cap each one where it is produced: the QML collector
# on the other end buffers whatever arrives with no limit of its own, so a
# runaway or hostile helper would otherwise grow the shell's heap unbounded.
MAX_SMI=4096              # four short CSV fields
MAX_LSPCI=65536           # one device line
MAX_DF=65536              # one line per mount
MAX_PS=16384              # five lines, twice
MAX_OUTPUT=1048576        # this script's own stdout
CMD_TIMEOUT=5             # per external helper; the widget also has a deadline

# Run an external helper under a time limit. A sensor that never answers - a
# wedged i2c bus, a dGPU that will not wake - stops the sample instead of
# holding the single in-flight slot until the widget's watchdog fires.
run() { timeout -s KILL "$CMD_TIMEOUT" "$@"; }

usage() {
  cat <<'EOF'
Usage: hwmon.sh [stats] [--full]
       hwmon.sh reap PID MIN_AGE_SECONDS
       hwmon.sh --help

  stats        Emit one line of JSON describing the current hardware state.
  --full       Also collect NVIDIA GPU stats, storage devices and top processes.
               Costs more and can wake a sleeping discrete GPU, so the widget
               only asks for it while its panel is open.
  reap         Tear down a wedged sample's process group, identity re-checked
               from /proc first. The widget's watchdog is what asks for this.
EOF
}

# --------------------------------------------------------------------- reaping
# The widget asks for this when a sample has outlived its deadline and ignored
# SIGTERM. Everything it acts on is re-derived from /proc here rather than taken
# on trust from the QML side, which knows only a number that was a pid when the
# watchdog fired:
#
#   - the target must still be its own process group and session leader, which
#     is what `setsid` made it and what makes a group kill safe;
#   - it must have been running for at least the deadline the widget was
#     waiting on, so a pid recycled since then is refused rather than killed;
#   - its command line must be this script, so an unrelated process that
#     inherited the number is refused as well;
#   - and the group must not be our own.
#
# If the leader has already gone, its descendants can still be holding the pipe,
# so the group is swept anyway - but only when nothing has taken the leader's
# pid, and only for members old enough to predate the deadline.
#
# "Reaping" here means confirming the group is gone: the direct child belongs to
# the shell's own process table (Quickshell waits on it), and anything below it
# is reparented to init, which reaps it.
REAP_SETTLE=20            # 100ms each, so two seconds between TERM and KILL
HWMON_SELF=$0             # what a process of ours has in its command line
CLK_TCK=100               # replaced with the real value before it is used
PSTAT_PGRP=; PSTAT_SID=; PSTAT_START=; PSTAT_AGE=

# Sets PSTAT_PGRP / PSTAT_SID / PSTAT_START for a pid, without forking: the
# group sweep below walks every process on the machine, and a command
# substitution there would cost a subshell per process per pass.
proc_stat_fields() {      # $1 = pid
  local line after
  # The stderr redirection comes first on purpose: a process that exits while
  # the sweep is walking /proc makes the *input* redirection fail, and bash
  # reports that before a later 2>/dev/null would have applied.
  IFS= read -r line 2>/dev/null < "/proc/$1/stat" || return 1
  # comm sits in parentheses and may contain spaces and ')' - only the last
  # ") " in the line ends it, because no field after it contains that pair.
  after=${line##*') '}
  local -a f=($after)
  [ ${#f[@]} -ge 20 ] || return 1
  PSTAT_PGRP=${f[2]}; PSTAT_SID=${f[3]}; PSTAT_START=${f[19]}
  return 0
}

proc_age() {              # $1 = starttime in clock ticks; sets PSTAT_AGE
  local up
  IFS='. ' read -r up _ < /proc/uptime 2>/dev/null || return 1
  PSTAT_AGE=$(( up - $1 / CLK_TCK ))
  return 0
}

proc_is_ours() {          # $1 = pid: does its command line name this script?
  local a
  while IFS= read -r -d '' a; do
    [ "$a" = "$HWMON_SELF" ] && return 0
  done 2>/dev/null < "/proc/$1/cmdline"
  return 1
}

# True when no process is left in the group, and while walking it, refuses the
# sweep outright if a member is younger than $2 - a group that gained a new
# member since the deadline is a pid that has been recycled, not our sample.
group_gone() {            # $1 = pgid, $2 = minimum age of any member
  local p
  for p in /proc/[0-9]*; do
    p=${p##*/}
    proc_stat_fields "$p" || continue
    [ "$PSTAT_PGRP" = "$1" ] || continue
    proc_age "$PSTAT_START" || return 1
    [ "$PSTAT_AGE" -ge "$2" ] 2>/dev/null || return 2   # too young: not ours
    return 1
  done
  return 0
}

reap() {
  local pid=${1:-} minage=${2:-0} own i rc
  case $pid in *[!0-9]*|'') printf 'hwmon.sh: reap takes a pid\n' >&2; exit 2 ;; esac
  case $minage in *[!0-9]*|'') minage=0 ;; esac
  [ "$pid" -gt 1 ] 2>/dev/null || exit 2
  CLK_TCK=$(getconf CLK_TCK 2>/dev/null) || CLK_TCK=100
  [ "$CLK_TCK" -gt 0 ] 2>/dev/null || CLK_TCK=100

  proc_stat_fields $$ || exit 1
  own=$PSTAT_PGRP
  [ "$pid" != "$own" ] || exit 1                   # never our own group

  if proc_stat_fields "$pid"; then
    # A pid that came back as something else since the watchdog fired fails at
    # least one of these, and nothing is signalled.
    [ "$PSTAT_PGRP" = "$pid" ] && [ "$PSTAT_SID" = "$pid" ] || exit 1
    [ "$PSTAT_PGRP" != "$own" ] || exit 1
    proc_age "$PSTAT_START" || exit 1
    [ "$PSTAT_AGE" -ge "$minage" ] 2>/dev/null || exit 1
    proc_is_ours "$pid" || exit 1
  else
    # The leader is gone. Sweeping its group is only safe while no new process
    # holds that number, and only if every survivor predates the deadline.
    group_gone "$pid" "$minage"; rc=$?
    [ "$rc" = 0 ] && exit 0
    [ "$rc" = 1 ] || exit 1
  fi

  # Between signals the group is re-examined rather than assumed: if something
  # newer than the deadline has appeared in it, the numbers have been recycled
  # underneath us and the right move is to stop signalling, not to press on.
  settle() {
    local i rc
    for ((i = 0; i < REAP_SETTLE; i++)); do
      group_gone "$pid" "$minage"; rc=$?
      [ "$rc" = 0 ] && exit 0
      [ "$rc" = 2 ] && exit 1
      sleep 0.1
    done
    return 0
  }

  kill -TERM -- "-$pid" 2>/dev/null || :
  settle
  kill -KILL -- "-$pid" 2>/dev/null || :
  settle
  printf 'hwmon.sh: process group %s outlived SIGKILL\n' "$pid" >&2
  exit 1
}

FULL=0
case "${1:-}" in
  reap) reap "${2:-}" "${3:-}"; exit 0 ;;
esac

for arg in "$@"; do
  case "$arg" in
    stats)      ;;
    --full)     FULL=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          printf 'hwmon.sh: unknown argument: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# jq builds and escapes every string that reaches the output, so there is no
# degraded mode without it. Report it in-band: the widget shows the message
# instead of a readout that silently reads zero.
if ! have jq; then
  printf '{"error":"hwmon: jq is not installed"}\n'
  exit 1
fi

# Read a single-line file without forking cat.
rd() { local v=""; [ -r "$1" ] && IFS= read -r v <"$1" 2>/dev/null; printf '%s' "$v"; }

# Echo the argument if it is a plain number, else the fallback (default null).
# Everything passed to `jq --argjson` goes through this: a sensor that returns
# "N/A", an empty sysfs read or a truncated file would otherwise abort jq and
# take a whole section of the panel down with it.
#
# This and the two helpers below were an `awk` each. They are called around
# forty times per sample, and a sample runs every 1.5-3 seconds forever: at that
# rate the process spawns cost more than everything they were measuring. Bash
# can answer all three questions itself, so it does.
num() {
  if [[ ${1-} =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf '%s' "$1"
  else printf '%s' "${2-null}"; fi
}

# Round a number to a whole one in $ROUND, or "null" if it is not a number.
# (printf rounds half to even, which is what awk's "%.0f" did too.)
ROUND=null
round() {
  if [[ ${1-} =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf -v ROUND '%.0f' "$1"
  else ROUND=${2-null}; fi
}

# Millidegrees (what hwmon files hold) to whole degrees, or "null".
mdeg() {
  if [[ ${1-} =~ ^-?[0-9]+$ ]]; then
    if [ "$1" -ge 0 ]; then printf '%s' "$(( ($1 + 500) / 1000 ))"
    else printf '%s' "$(( ($1 - 500) / 1000 ))"; fi
  else printf 'null'; fi
}

# Collapse runs of whitespace and trim both ends.
squish() {
  local v="$*"
  v=${v//[$' \t\n\r']/ }               # any whitespace is a space
  while [[ $v == *"  "* ]]; do v=${v//  / }; done
  v=${v# }; v=${v% }
  printf '%s' "$v"
}

# Human-friendly GPU model name for a PCI address (e.g. 0000:06:00.0), via
# lspci: "Cezanne [Radeon Vega Series / Radeon Mobile Series]" -> "Radeon Vega
# Series", "GA106M [GeForce RTX 3060 Mobile]" -> "GeForce RTX 3060 Mobile".
# Prints nothing if lspci is missing or the slot has no readable name.
gpu_model() {
  have lspci || return 0
  local dev
  dev=$(run lspci -mm -s "$1" 2>/dev/null | head -c "$MAX_LSPCI" | head -1 | grep -oE '"[^"]*"' | sed -n '3p' | tr -d '"')
  [ -n "$dev" ] || return 0
  # Prefer the marketing name lspci puts in [brackets] after the codename.
  [[ $dev =~ \[([^]]+)\] ]] && dev=${BASH_REMATCH[1]}
  dev=${dev%% / *}          # collapse "Radeon ... / Radeon ..." to the first
  printf '%s' "$(squish "$dev")"
}

# Intel GPUs on the xe/i915 drivers expose no gpu_busy_percent counter (that is
# AMD's); their engine busyness is recovered from the DRM clients' cycle
# counters in /proc/<pid>/fdinfo instead. One client can hold several render
# fds and every one carries the same counters, so a key of (pdev, client-id,
# engine) is assigned rather than summed - reading a client twice cannot double
# its cycles.
#
# The clients are found once per sample and both snapshots read the same file
# list, so opening every fdinfo on the machine is paid once rather than twice.
drm_clients() {
  # `find ... -exec +` rather than a bare glob: /proc/*/fdinfo/* is one path per
  # open descriptor on the machine, which on a busy desktop is tens of thousands
  # of arguments and would fail the exec outright. find batches them under the
  # limit; the starting points are one per process, which is small.
  find /proc/[0-9]*/fdinfo -maxdepth 1 -type f \
    -exec grep -lE '^drm-driver:[[:space:]]*(xe|i915)$' {} + 2>/dev/null
}

drm_snapshot() {   # $@ = fdinfo files
  [ $# -gt 0 ] || return 0
  awk '
    /^drm-pdev:/         { pdev = $2 }
    /^drm-client-id:/    { cid = $2 }
    /^drm-cycles-/       { e = $1; sub(/^drm-cycles-/, "", e); cyc[pdev SUBSEP cid SUBSEP e] = $2 }
    /^drm-total-cycles-/ { e = $1; sub(/^drm-total-cycles-/, "", e); tot[pdev SUBSEP cid SUBSEP e] = $2 }
    END { for (k in cyc) { split(k, a, SUBSEP); print a[1] "\t" a[2] "\t" a[3] "\t" cyc[k] "\t" tot[k] } }
  ' "$@" 2>/dev/null
}

# Busiest engine of one card, as a whole percentage, from the two snapshots in
# $DRM1 / $DRM2: the summed per-client cycle deltas over the window divided by
# the engine's own tick delta. "null" when neither snapshot held the card.
drm_busy() {   # $1 = pci address
  awk -F'\t' -v pdev="$1" '
    NR == FNR { if ($1 == pdev) { c[$2 SUBSEP $3] = $4; t[$2 SUBSEP $3] = $5 } next }
    { if ($1 != pdev) next
      k = $2 SUBSEP $3; if (!(k in c)) next
      dc = $4 - c[k]; dt = $5 - t[k]
      if (dt > 0) { busy[$3] += dc; total[$3] = dt } }
    END { best = -1
      for (e in busy) if (total[e] > 0) {
        u = 100 * busy[e] / total[e]; if (u < 0) u = 0
        if (u > best) best = u
      }
      if (best < 0) print "null"
      else { if (best > 100) best = 100; printf "%.0f", best } }
  ' <(printf '%s\n' "$DRM1") <(printf '%s\n' "$DRM2")
}

# ---------------------------------------------------------------- CPU + network
# Both need a delta across a short window, so take the two snapshots back to
# back around one sleep.

# The cpu lines come first in /proc/stat, so this stops as soon as they end.
# `mapfile` rather than a `read` loop: bash's `read` asks the kernel for one
# byte at a time so it can leave the descriptor exactly after the newline, which
# on a 30 KB /proc file costs more than everything else in the sample put
# together. mapfile takes the file in one pass.
cpu_snap() {
  local -a lines; local line
  CPU_SNAP=
  mapfile -t lines < /proc/stat
  for line in "${lines[@]}"; do
    case $line in
      cpu\ *|cpu[0-9]*\ *) CPU_SNAP+=$line$'\n' ;;
      *) break ;;
    esac
  done
}

cpu_snap; cpu_snap1=$CPU_SNAP

declare -A NET_RX1 NET_TX1
for dev in /sys/class/net/*; do
  ifc=${dev##*/}
  [ "$ifc" = "lo" ] && continue
  [ "$(rd "$dev/operstate")" = "up" ] || continue
  NET_RX1[$ifc]=$(num "$(rd "$dev/statistics/rx_bytes")" 0)
  NET_TX1[$ifc]=$(num "$(rd "$dev/statistics/tx_bytes")" 0)
done
t1=${EPOCHREALTIME:-$(date +%s.%N)}

# Cards whose utilisation has to come from fdinfo rather than a sysfs counter
# (Intel's xe/i915) are snapshotted across the same window as the CPU and
# network deltas, so they cost no extra sleep. DRM_CARDS holds their PCI
# addresses; DRM1 / DRM2 are the before/after readings.
drm_driver_of() {   # $1 = a card's device directory; result in $DRM_DRIVER
  DRM_DRIVER=$(readlink -f "$1/driver" 2>/dev/null)
  DRM_DRIVER=${DRM_DRIVER##*/}
  return 0
}

DRM_CARDS=()
for dev in /sys/class/drm/card*/device; do
  [ -r "$dev/gpu_busy_percent" ] && continue
  drm_driver_of "$dev"
  case $DRM_DRIVER in xe|i915) DRM_CARDS+=("$dev") ;; esac
done
DRM_FILES=()
DRM1=; DRM2=
if [ ${#DRM_CARDS[@]} -gt 0 ]; then mapfile -t DRM_FILES < <(drm_clients); fi
[ ${#DRM_FILES[@]} -gt 0 ] && DRM1=$(drm_snapshot "${DRM_FILES[@]}")

sleep "$SAMPLE_INTERVAL"

cpu_snap; cpu_snap2=$CPU_SNAP
t2=${EPOCHREALTIME:-$(date +%s.%N)}
[ ${#DRM_FILES[@]} -gt 0 ] && DRM2=$(drm_snapshot "${DRM_FILES[@]}")
dt=$(awk -v a="$t1" -v b="$t2" 'BEGIN { d = b - a; if (d <= 0) d = 0.35; print d }')

read -r CPU_PCT CPU_CORES_JSON < <(
  awk -v s1="$cpu_snap1" -v s2="$cpu_snap2" '
    BEGIN {
      # Only lines that actually name a cpu count. A snapshot ends with a
      # newline, so the last field split() hands back is empty - and an empty
      # key used to fall through to the per-core branch below and add a
      # seventeenth core to a sixteen-thread machine, reading 0% forever.
      n1 = split(s1, L1, "\n")
      for (i = 1; i <= n1; i++) { split(L1[i], f, " "); key = f[1]
        if (key !~ /^cpu[0-9]*$/) continue
        tot = 0; for (j = 2; j <= 9; j++) tot += f[j]
        T1[key] = tot; I1[key] = f[5] + f[6] }
      n2 = split(s2, L2, "\n")
      overall = 0; cores = "["
      for (i = 1; i <= n2; i++) { split(L2[i], f, " "); key = f[1]
        if (key !~ /^cpu[0-9]*$/) continue
        tot = 0; for (j = 2; j <= 9; j++) tot += f[j]
        dtot = tot - T1[key]; didle = (f[5] + f[6]) - I1[key]
        u = (dtot > 0) ? (100 * (dtot - didle) / dtot) : 0
        if (u < 0) u = 0; if (u > 100) u = 100
        if (key == "cpu") { overall = u }
        else { cores = cores (cores == "[" ? "" : ",") sprintf("%.0f", u) }
      }
      cores = cores "]"
      printf "%.0f %s\n", overall, cores
    }'
)
jq -e . >/dev/null 2>&1 <<<"${CPU_CORES_JSON:-}" || CPU_CORES_JSON="[]"

# Which physical core each entry of cpu_cores sits on, so the panel can fold an
# SMT machine's threads back into cores. The thread order is taken from the same
# /proc/stat snapshot the percentages came from, because an offline cpu leaves a
# gap in the numbering and the two lists have to line up. Cores are renumbered
# in the order they first appear, so the labels read 0..n-1 whatever ids the
# kernel uses. Empty when the machine exposes no topology (some VMs, some ARM),
# and the panel falls back to showing threads.
CORE_OF_JSON="[]"
_core_of=""
declare -A _core_seen=()
_core_next=0
while IFS= read -r _line; do
  case $_line in cpu[0-9]*\ *) ;; *) continue ;; esac
  _n=${_line%% *}; _n=${_n#cpu}
  _topo=/sys/devices/system/cpu/cpu$_n/topology
  IFS= read -r _cid < "$_topo/core_id" 2>/dev/null || { _core_of=; break; }
  IFS= read -r _pkg < "$_topo/physical_package_id" 2>/dev/null || _pkg=0
  [[ $_cid =~ ^[0-9]+$ ]] || { _core_of=; break; }
  _key=$_pkg:$_cid
  if [ -z "${_core_seen[$_key]+x}" ]; then
    _core_seen[$_key]=$_core_next; _core_next=$((_core_next + 1))
  fi
  _core_of+="${_core_of:+,}${_core_seen[$_key]}"
done <<<"$cpu_snap2"
[ -n "$_core_of" ] && CORE_OF_JSON="[$_core_of]"
jq -e . >/dev/null 2>&1 <<<"$CORE_OF_JSON" || CORE_OF_JSON="[]"

# One jq for the whole interface list rather than one per interface. Interface
# names cannot contain whitespace, so a tab-separated line is unambiguous.
net_rows=""
for ifc in "${!NET_RX1[@]}"; do
  rx2=$(num "$(rd "/sys/class/net/$ifc/statistics/rx_bytes")" 0)
  tx2=$(num "$(rd "/sys/class/net/$ifc/statistics/tx_bytes")" 0)
  net_rows+=$(awk -v ifc="$ifc" -v r1="${NET_RX1[$ifc]}" -v r2="$rx2" \
                  -v x1="${NET_TX1[$ifc]}" -v x2="$tx2" -v dt="$dt" 'BEGIN {
    rx = (r2 - r1) / dt / 1024; tx = (x2 - x1) / dt / 1024
    if (rx < 0) rx = 0; if (tx < 0) tx = 0
    printf "%s\t%.1f\t%.1f", ifc, rx, tx
  }')$'\n'
done
NET_JSON=$(jq -Rsc '
  split("\n") | map(select(length > 0) | split("\t")
  | { iface: .[0], rx_kbs: (.[1] | tonumber), tx_kbs: (.[2] | tonumber) })
' <<<"$net_rows" 2>/dev/null)
[ -n "$NET_JSON" ] || NET_JSON="[]"

# ---------------------------------------------------------------- load / freq
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
# NCPU is set from the topology pass over /proc/cpuinfo further down, which
# counts the same threads `nproc` would have reported - so the number always
# agrees with cpu_topology.threads and with the per-core array, and one more
# external tool drops off the list.

FREQ_MHZ=$(awk '
  { s += $1; n++ }
  END { if (n > 0) printf "%.0f", (s / n) / 1000; else print "null" }
' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null)

FREQ_MAX_MHZ=$(awk '
  { if ($1 > m) m = $1 }
  END { if (m > 0) printf "%.0f", m / 1000; else print "null" }
' /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq 2>/dev/null)

# ---------------------------------------------------------- static system info
# All of this is dumb file parsing that works on any Linux box - no hard-coded
# device names, and every field falls back to null / a sane default.

CPU_MODEL=$(awk -F': ' '
  /^model name/ || /^Model name/ {
    m = $2
    gsub(/\((R|TM|tm|r)\)/, "", m)     # Intel(R) Core(TM) -> Intel Core
    sub(/ CPU @.*$/, "", m)             # ... i7-9750H CPU @ 2.60GHz -> ... i7-9750H
    gsub(/[ \t]+/, " ", m)
    sub(/^ /, "", m); sub(/ $/, "", m)
    print m; exit
  }' /proc/cpuinfo)
[ -z "$CPU_MODEL" ] && CPU_MODEL="$(uname -m) processor"

# Physical cores / logical threads / sockets from /proc/cpuinfo topology. Falls
# back to the thread count when an arch omits physical/core ids (VMs, some ARM).
read -r CORES_PHYS THREADS SOCKETS < <(awk -F': ' '
  /^processor/   { th++ }
  /^physical id/ { pid = $2; sock[pid] = 1 }
  /^core id/     { core[pid ":" $2] = 1 }
  /^cpu cores/   { cc = $2 }
  END {
    s = 0; for (k in sock) s++
    c = 0; for (k in core) c++
    if (s == 0) s = 1
    if (c == 0) c = (cc > 0 ? cc * s : th)
    print c, th, s
  }' /proc/cpuinfo)
NCPU=$THREADS
[ "${NCPU:-0}" -gt 0 ] 2>/dev/null || NCPU=1

dmi() { rd "/sys/devices/virtual/dmi/id/$1"; }
_sv=$(squish "$(dmi sys_vendor)"); _pf=$(squish "$(dmi product_family)")
_pn=$(squish "$(dmi product_name)"); _bn=$(squish "$(dmi board_name)")
_pv=$(squish "$(dmi product_version)")
_junk='Default string|To be filled by O\.E\.M\.|System Product Name|None|Not Applicable|N/A'
for _v in _pf _pn _pv; do [[ ${!_v} =~ ^($_junk)$ ]] && printf -v "$_v" '%s' ''; done
# Lenovo hides the friendly name ("ThinkPad X1 ...") in product_version.
case "$_sv" in LENOVO|Lenovo*) HOST_MODEL=${_pv:-${_pf:-$_pn}} ;; *) HOST_MODEL=${_pf:-$_pn} ;; esac
[ -n "$_bn" ] && HOST_MODEL=${HOST_MODEL%_$_bn}          # drop a duplicated "_BOARD" suffix
_sv=$(sed -E 's/ (COMPUTER )?(INC\.?|CORP\.?|CORPORATION|CO\.,? LTD\.?|GMBH|S\.A\.)//I; s/[.,]+$//; s/[[:space:]]+/ /g' <<<"$_sv")
[ "$_sv" = "ASUSTeK" ] && _sv="ASUS"
case "$HOST_MODEL" in
  ""|null)                                   HOST_MODEL=$_sv ;;
  "$_sv"*|ASUS*|Dell*|Lenovo*|LENOVO*|HP*|Hewlett*|MSI*|Micro-Star*|Acer*|Razer*|Gigabyte*|Framework*|Apple*|Microsoft*)
                                             : ;;
  *)                                         HOST_MODEL="${_sv:+$_sv }$HOST_MODEL" ;;
esac

IFS= read -r KERNEL < /proc/sys/kernel/osrelease 2>/dev/null || KERNEL=
ARCH=$(uname -m)
# /etc/os-release is shell syntax, but it is parsed rather than sourced: this
# script never executes the contents of a file it only means to read.
DISTRO=$(awk -F= '
  $1 == "PRETTY_NAME" || $1 == "NAME" {
    v = $2
    gsub(/^[ \t]*["\x27]?|["\x27]?[ \t]*$/, "", v)
    if ($1 == "PRETTY_NAME") { pretty = v } else if (name == "") { name = v }
  }
  END { print (pretty != "" ? pretty : (name != "" ? name : "Linux")) }
' /etc/os-release 2>/dev/null)
[ -n "$DISTRO" ] || DISTRO="Linux"

# ---------------------------------------------------------------- memory
read -r MEM_PCT MEM_USED_GIB MEM_TOTAL_GIB SWAP_PCT SWAP_USED_GIB SWAP_TOTAL_GIB < <(
  awk '
    /^MemTotal:/     { mt = $2 }
    /^MemAvailable:/ { ma = $2 }
    /^SwapTotal:/    { st = $2 }
    /^SwapFree:/     { sf = $2 }
    END {
      used = mt - ma
      printf "%.0f %.1f %.1f ", (mt > 0 ? 100 * used / mt : 0), used / 1048576, mt / 1048576
      sused = st - sf
      printf "%.0f %.1f %.1f\n", (st > 0 ? 100 * sused / st : 0), sused / 1048576, st / 1048576
    }
  ' /proc/meminfo
)

# ---------------------------------------------------------------- sensors
# Temperatures and fans come straight from the kernel's hwmon interface, which
# is where libsensors reads them from as well: one "<name>" per chip, and a
# tempN_input / fanN_input in millidegrees or RPM beside an optional
# tempN_label. Nothing here needs lm_sensors installed any more.
#
# It used to shell out to `sensors -j` once per sample. That cost 75-110 ms of
# a sample that runs every 1.5-3 seconds - about half the work in the whole
# sample, forever, on a laptop - and brought with it a 256 KB buffer, three jq
# passes to dig values back out, and a chip name derived from a PCI address,
# which is exactly the thing that silently broke GPU temperature on this
# hardware once before. Reading the files costs about two milliseconds.

# Millidegrees, so the comparisons below are integer ones.
TEMP_CPU=; TEMP_ANY=
fan_rows=""

hottest() {   # $1 = current max (may be empty), $2 = candidate; result in $HOT
  HOT=$1
  { [ -z "$HOT" ] || [ "$2" -gt "$HOT" ]; } && HOT=$2
  return 0
}

temp_label_of() {   # $1 = a tempN_input path; result in $TLABEL
  TLABEL=
  [ -r "${1%_input}_label" ] && IFS= read -r TLABEL < "${1%_input}_label" 2>/dev/null
  return 0
}

# Not every temperature costs the same to read. A sysfs file on a PCI device is
# a register read; acpitz and the vendor WMI chips evaluate an ACPI method, and
# those ran to tens of milliseconds per sample here. So ask the CPU's own driver
# first, by name, and only fall back to reading every sensor on the machine when
# this is a box where neither AMD's nor Intel's package sensor exists.
for _h in /sys/class/hwmon/hwmon*; do
  [ -r "$_h/name" ] || continue
  IFS= read -r _hname < "$_h/name" 2>/dev/null || continue
  case $_hname in k10temp|coretemp) ;; *) continue ;; esac
  for _f in "$_h"/temp*_input; do
    [ -r "$_f" ] || continue
    temp_label_of "$_f"
    case $_hname in
      k10temp)  case $TLABEL in Tdie|Tctl|Tccd*) ;; *) continue ;; esac ;;
      coretemp) case $TLABEL in "Package id"*)   ;; *) continue ;; esac ;;
    esac
    IFS= read -r _v < "$_f" 2>/dev/null || continue
    [[ $_v =~ ^-?[0-9]+$ ]] || continue
    hottest "$TEMP_CPU" "$_v"; TEMP_CPU=$HOT
  done
done

if [ -n "$TEMP_CPU" ]; then
  CPU_TEMP=$TEMP_CPU; CPU_TEMP_LABEL=CPU
else
  # No package sensor: report the hottest thing on the machine instead, which
  # is what the old `sensors -j` pass did in this case too.
  for _h in /sys/class/hwmon/hwmon*; do
    for _f in "$_h"/temp*_input; do
      [ -r "$_f" ] || continue
      IFS= read -r _v < "$_f" 2>/dev/null || continue
      [[ $_v =~ ^-?[0-9]+$ ]] || continue
      hottest "$TEMP_ANY" "$_v"; TEMP_ANY=$HOT
    done
  done
  CPU_TEMP=$TEMP_ANY; CPU_TEMP_LABEL=SYS
fi
CPU_TEMP=$(mdeg "$CPU_TEMP")

# Fan speeds only appear in the detail panel. A stopped fan reads 0 and is kept
# - on a laptop that idles fanless that row is how you can tell the fan is off
# rather than absent. Some machines expose one physical fan through two chips (a
# generic acpi_fan beside the EC's own hwmon) with the same name and rpm; those
# are listed once, preferring whichever reading carries a pwmN duty cycle. The
# kernel reports pwm as 0-255, folded into a percentage.
FAN_JSON="[]"
if [ "$FULL" = "1" ]; then
  declare -A fan_name=()
  declare -A fan_rpm=()
  declare -A fan_pwm=()
  fan_order=()
  for _h in /sys/class/hwmon/hwmon*; do
    for _f in "$_h"/fan*_input; do
      [ -r "$_f" ] || continue
      IFS= read -r _v < "$_f" 2>/dev/null || continue
      [[ $_v =~ ^[0-9]+$ ]] || continue
      temp_label_of "$_f"
      [ -n "$TLABEL" ] || { TLABEL=${_f##*/}; TLABEL=${TLABEL%_input}; }
      _name=$(squish "$TLABEL")

      # fan1_input -> pwm1, which the kernel reports as 0-255.
      _n=${_f##*fan}; _n=${_n%%_input}
      _pwm=null
      if [ -r "${_f%fan*_input}pwm${_n}" ]; then
        IFS= read -r _raw < "${_f%fan*_input}pwm${_n}" 2>/dev/null || _raw=
        [[ $_raw =~ ^[0-9]+$ ]] && _pwm=$(( (_raw * 100 + 127) / 255 ))
      fi

      # Keyed on name and rpm together, with the name kept beside it rather
      # than unpacked out of the key again - a label is free to contain any
      # character, including whatever separator the key uses.
      _key=$_name$'\x1f'$_v
      if [ -z "${fan_rpm[$_key]+x}" ]; then
        fan_order+=("$_key"); fan_name[$_key]=$_name
        fan_rpm[$_key]=$_v; fan_pwm[$_key]=$_pwm
      elif [ "$_pwm" != null ] && [ "${fan_pwm[$_key]}" = null ]; then
        fan_pwm[$_key]=$_pwm
      fi
    done
  done
  for _key in "${fan_order[@]}"; do
    fan_rows+="${fan_name[$_key]}	${fan_rpm[$_key]}	${fan_pwm[$_key]}"$'\n'
  done
  FAN_JSON=$(jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t")
    | { name: .[0], rpm: (.[1] | tonumber),
        pwm: (if .[2] == "null" then null else (.[2] | tonumber) end) })' <<<"$fan_rows" 2>/dev/null)
  [ -n "$FAN_JSON" ] || FAN_JSON="[]"
fi

# ---------------------------------------------------------------- GPUs
# Rows are "name<TAB>model<TAB>util<TAB>temp<TAB>mem_pct" and become JSON in a
# single jq pass below; `squish` has already removed any tab from the model.
gpu_rows=""

# AMD via the DRM sysfs busy counter; Intel's xe/i915 have none and use the
# fdinfo deltas taken around the sample window instead. The card's temperature
# and model name are shared by both paths.
for dev in /sys/class/drm/card*/device; do
  pci=$(readlink -f "$dev" 2>/dev/null); pci=${pci##*/}             # 0000:06:00.0
  vendor=$(rd "$dev/vendor")

  if [ -r "$dev/gpu_busy_percent" ]; then
    busy=$(num "$(rd "$dev/gpu_busy_percent")" 0)
  else
    drm_driver_of "$dev"
    case $DRM_DRIVER in xe|i915) ;; *) continue ;; esac
    busy=$(drm_busy "$pci")
  fi

  name="GPU"
  temp_raw=
  model=$(gpu_model "$pci")

  # The card's own hwmon, which is a directory inside the card's device node -
  # so there is no chip name to derive and no way to attribute one card's
  # temperature to another. (Deriving "<driver>-pci-<bbdf>" for libsensors is
  # what used to break here when the address moved.) AMD labels the sensor
  # edge / junction / mem; Intel's i915 and xe expose a single one.
  for _f in "$dev"/hwmon/hwmon*/temp*_input "$dev"/hwmon*/temp*_input; do
    [ -r "$_f" ] || continue
    _lab=
    [ -r "${_f%_input}_label" ] && IFS= read -r _lab < "${_f%_input}_label" 2>/dev/null
    case ${_lab:-edge} in
      edge|junction|GPU*|gpu*) ;;
      *) [ -n "$temp_raw" ] && continue ;;     # keep looking for a better label
    esac
    IFS= read -r _v < "$_f" 2>/dev/null || continue
    [[ $_v =~ ^-?[0-9]+$ ]] || continue
    temp_raw=$_v
    case ${_lab:-edge} in edge|junction|GPU*|gpu*) break ;; esac
  done

  case "$vendor" in
    0x1002) name="AMD" ;;
    0x8086) name="Intel" ;;
    0x10de) name="NVIDIA" ;;
  esac
  temp=$(mdeg "$temp_raw")
  gpu_rows+="$name	$model	$busy	$temp	null"$'\n'
done

# NVIDIA only in --full mode: nvidia-smi can spin the dGPU up.
if [ "$FULL" = "1" ] && have nvidia-smi; then
  nv=$(run nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total \
         --format=csv,noheader,nounits 2>/dev/null | head -c "$MAX_SMI" | head -1)
  nv_name=$(run nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -c "$MAX_SMI" | head -1)
  nv_name=$(squish "${nv_name#NVIDIA }")   # "NVIDIA GeForce RTX 3060" -> "GeForce RTX 3060"
  if [ -n "$nv" ]; then
    IFS=', ' read -r nv_util nv_temp nv_mu nv_mt <<<"$nv"
    # nvidia-smi answers "[N/A]" for counters a card or driver does not expose
    # (common on hybrid laptops); each field degrades to null on its own.
    nv_util=$(num "${nv_util:-}")
    nv_temp=$(num "${nv_temp:-}")
    nv_mem_pct=null
    if [[ ${nv_mu:-} =~ ^[0-9]+$ && ${nv_mt:-} =~ ^[0-9]+$ ]] && [ "$nv_mt" -gt 0 ]; then
      nv_mem_pct=$(( 100 * nv_mu / nv_mt ))
    fi
    gpu_rows+="NVIDIA	$nv_name	$nv_util	$nv_temp	$nv_mem_pct"$'\n'
  fi
fi

GPU_JSON=$(jq -Rsc '
  def n: if . == "null" or . == "" then null else tonumber end;
  split("\n") | map(select(length > 0) | split("\t")
  | { name: .[0],
      model: (if .[1] == "" then null else .[1] end),
      util: (.[2] | n), temp: (.[3] | n), mem_pct: (.[4] | n) })
' <<<"$gpu_rows" 2>/dev/null)
[ -n "$GPU_JSON" ] || GPU_JSON="[]"

# ---------------------------------------------------------------- disks
# `target` comes last and is captured to end of line: a mount point may contain
# spaces (a USB stick labelled "My Drive" lands on /run/media/<user>/My Drive),
# and splitting on whitespace silently attributed its size to the wrong column.
DISK_JSON=$(
  run df -B1 --output=source,pcent,used,size,target \
     -x tmpfs -x devtmpfs -x efivarfs -x squashfs -x overlay -x ramfs 2>/dev/null \
  | head -c "$MAX_DF" | tail -n +2 \
  | jq -Rsc '
      [ split("\n")[]
        | select(length > 0)
        | capture("^(?<src>.*?)[ \t]+(?<pct>[0-9]+)%[ \t]+(?<used>[0-9]+)[ \t]+(?<size>[0-9]+)[ \t]+(?<tgt>.+)$")
        | { mount: .tgt,
            src: .src,
            dev: (.src | sub(".*/"; "") | sub("p?[0-9]+$"; "")),
            pct: (.pct | tonumber),
            used_gib: ((.used | tonumber) / 1073741824 * 10 | round / 10),
            total_gib: ((.size | tonumber) / 1073741824 * 10 | round / 10) } ]
      # btrfs subvolumes repeat one device; keep the first mount of each.
      | reduce .[] as $d ({ seen: {}, out: [] };
          if .seen[$d.src] then . else { seen: (.seen + { ($d.src): true }), out: (.out + [$d]) } end)
      | .out | map(del(.src))
    '
)
[ -n "$DISK_JSON" ] || DISK_JSON="[]"

# --------------------------------------------------------- storage devices
# Physical block devices with model / bus / capacity / temperature, straight
# from sysfs so it needs no extra tools and adapts to whatever is plugged in.
# Only gathered with --full (panel open), like the top-process list.
STORAGE_JSON="[]"
if [ "$FULL" = "1" ]; then
  storage_rows=""
  for blk in /sys/block/*; do
    bn=${blk##*/}
    case "$bn" in loop*|ram*|zram*|md*|dm-*|sr*|fd*) continue ;; esac
    sectors=$(num "$(rd "$blk/size")" 0)
    [ "${sectors%%.*}" -gt 0 ] 2>/dev/null || continue

    rota=$(rd "$blk/queue/rotational")
    dmodel=$(squish "$(rd "$blk/device/model")")
    [ -z "$dmodel" ] && dmodel=$(squish "$(rd "$blk/device/name")")
    dvendor=$(squish "$(rd "$blk/device/vendor")")
    case "$dvendor" in ""|ATA|"Generic"|"Linux") ;; *) dmodel=$(squish "$dvendor $dmodel") ;; esac
    [ -z "$dmodel" ] && dmodel=$bn

    case "$bn" in
      nvme*)   tran=NVMe ;;
      mmcblk*) tran="eMMC/SD" ;;
      *) if readlink -f "$blk/device" 2>/dev/null | grep -q '/usb'; then tran=USB; else tran=SATA; fi ;;
    esac
    [ "$rota" = "1" ] && kind=HDD || kind=SSD

    dtemp=null
    for h in "$blk"/device/hwmon*/temp1_input "$blk"/device/hwmon/hwmon*/temp1_input; do
      [ -r "$h" ] || continue
      IFS= read -r _mdeg <"$h" 2>/dev/null || _mdeg=
      if [[ $_mdeg =~ ^-?[0-9]+$ ]]; then            # millidegrees, always whole
        if [ "$_mdeg" -ge 0 ]; then dtemp=$(( (_mdeg + 500) / 1000 ))
        else dtemp=$(( (_mdeg - 500) / 1000 )); fi
      fi
      break
    done

    size_gb=$(awk -v s="$sectors" 'BEGIN { printf "%.1f", s * 512 / 1e9 }')
    storage_rows+="$bn	$dmodel	$tran	$kind	$size_gb	$dtemp"$'\n'
  done
  STORAGE_JSON=$(jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t")
    | { name: .[0], model: .[1], tran: .[2], kind: .[3],
        size_gb: (.[4] | tonumber),
        temp: (if .[5] == "null" then null else (.[5] | tonumber) end) })
  ' <<<"$storage_rows" 2>/dev/null)
  [ -n "$STORAGE_JSON" ] || STORAGE_JSON="[]"
fi

# ---------------------------------------------------------------- battery
BAT_JSON=null
for bat in /sys/class/power_supply/BAT*; do
  [ -r "$bat/capacity" ] || continue
  cap=$(num "$(rd "$bat/capacity")" 0)
  status=$(rd "$bat/status")
  BAT_JSON=$(jq -nc --argjson c "$cap" --arg s "${status:-Unknown}" '{pct:$c, status:$s}')
  break
done

# ---------------------------------------------------------------- uptime
IFS='. ' read -r _up _ < /proc/uptime 2>/dev/null || _up=0
[[ $_up =~ ^[0-9]+$ ]] || _up=0
_d=$(( _up / 86400 )); _h=$(( (_up % 86400) / 3600 )); _m=$(( (_up % 3600) / 60 ))
if   [ "$_d" -gt 0 ]; then printf -v UPTIME_STR '%dd %dh' "$_d" "$_h"
elif [ "$_h" -gt 0 ]; then printf -v UPTIME_STR '%dh %dm' "$_h" "$_m"
else                       printf -v UPTIME_STR '%dm' "$_m"
fi

# ---------------------------------------------------------------- top processes
# A process name is attacker-influenced text: any user can run a binary called
# `a"b`, and comm keeps spaces (Firefox's "Web Content"). jq does the quoting,
# and the percentage is anchored to the end of the line so a name with spaces
# survives intact instead of being cut at the first one.
TOP_CPU_JSON="[]"
TOP_MEM_JSON="[]"
top_procs() {
  run ps -eo "comm,$1" --sort="-$1" --no-headers 2>/dev/null | head -c "$MAX_PS" | head -5 | jq -Rsc '
    split("\n") | map(select(length > 0)
    | capture("^(?<name>.*\\S)[ \t]+(?<pct>[0-9]+(\\.[0-9]+)?)[ \t]*$")
    | { name: .name, pct: (.pct | tonumber) })'
}
if [ "$FULL" = "1" ]; then
  TOP_CPU_JSON=$(top_procs %cpu); [ -n "$TOP_CPU_JSON" ] || TOP_CPU_JSON="[]"
  TOP_MEM_JSON=$(top_procs %mem); [ -n "$TOP_MEM_JSON" ] || TOP_MEM_JSON="[]"
fi

# ---------------------------------------------------------------- assemble
jq -nc \
  --argjson cpu_pct "$(num "${CPU_PCT:-}" 0)" \
  --argjson cpu_cores "$CPU_CORES_JSON" \
  --argjson cpu_core_of "$CORE_OF_JSON" \
  --argjson ncpu "$(num "${NCPU:-}" 1)" \
  --argjson load "[$(num "${LOAD1:-}" 0),$(num "${LOAD5:-}" 0),$(num "${LOAD15:-}" 0)]" \
  --argjson freq_mhz "$(num "${FREQ_MHZ:-}")" \
  --argjson freq_max_mhz "$(num "${FREQ_MAX_MHZ:-}")" \
  --arg cpu_model "${CPU_MODEL:-}" \
  --argjson cores_phys "$(num "${CORES_PHYS:-}" 0)" \
  --argjson threads "$(num "${THREADS:-}" 0)" \
  --argjson sockets "$(num "${SOCKETS:-}" 1)" \
  --arg host_model "${HOST_MODEL:-}" \
  --arg kernel "${KERNEL:-}" \
  --arg arch "${ARCH:-}" \
  --arg distro "${DISTRO:-}" \
  --argjson storage "$STORAGE_JSON" \
  --argjson mem_pct "$(num "${MEM_PCT:-}" 0)" \
  --argjson mem_used_gib "$(num "${MEM_USED_GIB:-}" 0)" \
  --argjson mem_total_gib "$(num "${MEM_TOTAL_GIB:-}" 0)" \
  --argjson swap_pct "$(num "${SWAP_PCT:-}" 0)" \
  --argjson swap_used_gib "$(num "${SWAP_USED_GIB:-}" 0)" \
  --argjson swap_total_gib "$(num "${SWAP_TOTAL_GIB:-}" 0)" \
  --argjson temp_c "$(num "${CPU_TEMP:-}")" \
  --arg temp_label "${CPU_TEMP_LABEL:-SYS}" \
  --argjson fans "$FAN_JSON" \
  --argjson gpus "$GPU_JSON" \
  --argjson disks "$DISK_JSON" \
  --argjson net "$NET_JSON" \
  --argjson battery "$BAT_JSON" \
  --arg uptime "${UPTIME_STR:-?}" \
  --argjson top_cpu "$TOP_CPU_JSON" \
  --argjson top_mem "$TOP_MEM_JSON" \
  --argjson full "$FULL" \
  '{
    cpu_pct: $cpu_pct, cpu_cores: $cpu_cores, cpu_core_of: $cpu_core_of,
    ncpu: $ncpu, load: $load,
    freq_mhz: $freq_mhz, freq_max_mhz: $freq_max_mhz,
    cpu_model: (if $cpu_model == "" then null else $cpu_model end),
    cpu_topology: { cores: $cores_phys, threads: $threads, sockets: $sockets },
    host: {
      model: (if $host_model == "" then null else $host_model end),
      kernel: $kernel, arch: $arch, distro: $distro
    },
    mem_pct: $mem_pct, mem_used_gib: $mem_used_gib, mem_total_gib: $mem_total_gib,
    swap_pct: $swap_pct, swap_used_gib: $swap_used_gib, swap_total_gib: $swap_total_gib,
    temp_c: $temp_c, temp_label: $temp_label, fans: $fans, gpus: $gpus,
    disks: $disks, storage: $storage, net: $net, battery: $battery, uptime: $uptime,
    top_cpu: $top_cpu, top_mem: $top_mem, full: ($full == 1)
  }' | head -c "$MAX_OUTPUT"
