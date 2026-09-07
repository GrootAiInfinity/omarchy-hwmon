#!/usr/bin/env bash
# Hardware monitor backend for the custom omarchy bar module (hwmon.qml).
#
#   hwmon.sh stats          Lightweight sample: CPU, memory, load, temps, fans,
#                           AMD GPU, disks, network, battery, uptime.
#   hwmon.sh stats --full   Everything above plus NVIDIA GPU (nvidia-smi, which
#                           can wake the dGPU) and the top processes by CPU/RAM.
#
# Output is a single line of JSON on stdout. Missing metrics are emitted as
# null / empty arrays so the QML side can just check for them.

set -u

SAMPLE_INTERVAL=0.35
MODE="${1:-stats}"
FULL=0
[ "${2:-}" = "--full" ] && FULL=1
[ "${1:-}" = "--full" ] && FULL=1

have() { command -v "$1" >/dev/null 2>&1; }

# Human-friendly GPU model name for a PCI address (e.g. 0000:06:00.0), via
# lspci: "Renoir [Radeon Vega Series / Radeon Vega Mobile Series]" -> "Radeon
# Vega Series", "TU106M [GeForce RTX 2060 Mobile]" -> "GeForce RTX 2060 Mobile".
# Prints nothing if lspci is missing or the slot has no readable name.
gpu_model() {
  have lspci || return 0
  local dev
  dev=$(lspci -mm -s "$1" 2>/dev/null | head -1 | grep -oE '"[^"]*"' | sed -n '3p' | tr -d '"')
  [ -n "$dev" ] || return 0
  # Prefer the marketing name lspci puts in [brackets] after the codename.
  [[ $dev =~ \[([^]]+)\] ]] && dev=${BASH_REMATCH[1]}
  dev=${dev%% / *}          # collapse "Radeon Vega Series / ..." to the first
  printf '%s' "$dev"
}

# ---------------------------------------------------------------- CPU + network
# Both need a delta across a short window, so take the two snapshots back to
# back around one sleep.

cpu_snap1=$(grep -E '^cpu[0-9]* ' /proc/stat)

declare -A NET_RX1 NET_TX1
for dev in /sys/class/net/*; do
  ifc=${dev##*/}
  [ "$ifc" = "lo" ] && continue
  [ "$(cat "$dev/operstate" 2>/dev/null)" = "up" ] || continue
  NET_RX1[$ifc]=$(cat "$dev/statistics/rx_bytes" 2>/dev/null || echo 0)
  NET_TX1[$ifc]=$(cat "$dev/statistics/tx_bytes" 2>/dev/null || echo 0)
done
t1=${EPOCHREALTIME:-$(date +%s.%N)}

sleep "$SAMPLE_INTERVAL"

cpu_snap2=$(grep -E '^cpu[0-9]* ' /proc/stat)
t2=${EPOCHREALTIME:-$(date +%s.%N)}
dt=$(awk -v a="$t1" -v b="$t2" 'BEGIN { d = b - a; if (d <= 0) d = 0.35; print d }')

read -r CPU_PCT CPU_CORES_JSON < <(
  awk -v s1="$cpu_snap1" -v s2="$cpu_snap2" '
    BEGIN {
      n1 = split(s1, L1, "\n")
      for (i = 1; i <= n1; i++) { split(L1[i], f, " "); key = f[1]
        tot = 0; for (j = 2; j <= 9; j++) tot += f[j]
        T1[key] = tot; I1[key] = f[5] + f[6] }
      n2 = split(s2, L2, "\n")
      overall = 0; cores = "["
      for (i = 1; i <= n2; i++) { split(L2[i], f, " "); key = f[1]
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

NET_JSON="[]"
for ifc in "${!NET_RX1[@]}"; do
  rx2=$(cat "/sys/class/net/$ifc/statistics/rx_bytes" 2>/dev/null || echo 0)
  tx2=$(cat "/sys/class/net/$ifc/statistics/tx_bytes" 2>/dev/null || echo 0)
  entry=$(awk -v ifc="$ifc" -v r1="${NET_RX1[$ifc]}" -v r2="$rx2" \
              -v x1="${NET_TX1[$ifc]}" -v x2="$tx2" -v dt="$dt" 'BEGIN {
    rx = (r2 - r1) / dt / 1024; tx = (x2 - x1) / dt / 1024
    if (rx < 0) rx = 0; if (tx < 0) tx = 0
    printf "{\"iface\":\"%s\",\"rx_kbs\":%.1f,\"tx_kbs\":%.1f}", ifc, rx, tx
  }')
  NET_JSON=$(jq -c --argjson e "$entry" '. + [$e]' <<<"$NET_JSON")
done

# ---------------------------------------------------------------- load / freq
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
NCPU=$(nproc 2>/dev/null || echo 1)

FREQ_MHZ=$(awk '
  { s += $1; n++ }
  END { if (n > 0) printf "%.0f", (s / n) / 1000; else print "null" }
' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null)
[ -z "$FREQ_MHZ" ] && FREQ_MHZ=null

# ---------------------------------------------------------------- memory
read -r MEM_TOTAL MEM_AVAIL SWAP_TOTAL SWAP_FREE < <(
  awk '
    /^MemTotal:/     { mt = $2 }
    /^MemAvailable:/ { ma = $2 }
    /^SwapTotal:/    { st = $2 }
    /^SwapFree:/     { sf = $2 }
    END { print mt, ma, st, sf }
  ' /proc/meminfo
)
read -r MEM_PCT MEM_USED_GIB MEM_TOTAL_GIB SWAP_PCT SWAP_USED_GIB SWAP_TOTAL_GIB < <(
  awk -v mt="$MEM_TOTAL" -v ma="$MEM_AVAIL" -v st="$SWAP_TOTAL" -v sf="$SWAP_FREE" 'BEGIN {
    used = mt - ma
    printf "%.0f %.1f %.1f ", (mt > 0 ? 100 * used / mt : 0), used / 1048576, mt / 1048576
    sused = st - sf
    printf "%.0f %.1f %.1f\n", (st > 0 ? 100 * sused / st : 0), sused / 1048576, st / 1048576
  }'
)

# ---------------------------------------------------------------- sensors
SENSORS_JSON="{}"
have sensors && SENSORS_JSON=$(sensors -j 2>/dev/null || echo '{}')
# Guard against sensors emitting warnings that break JSON.
echo "$SENSORS_JSON" | jq -e . >/dev/null 2>&1 || SENSORS_JSON="{}"

# Pull the CPU/package temperature. Try AMD (k10temp: Tctl/Tdie/Tccd*), then
# Intel (coretemp: "Package id *"), then fall back to the hottest generic
# tempN_input on any chip and label it SYS.
read -r CPU_TEMP CPU_TEMP_LABEL < <(
  jq -r '
    def inputs_of($obj): [ $obj | to_entries[] | select(.key|test("_input$")) | .value ];
    ( [ to_entries[] | select(.key|test("k10temp"))    | .value
        | to_entries[] | select(.key|test("Tdie|Tctl|Tccd"; "i")) | .value | inputs_of(.)[] ] ) as $amd
    | ( [ to_entries[] | select(.key|test("coretemp")) | .value
        | to_entries[] | select(.key|test("Package id"; "i")) | .value | inputs_of(.)[] ] ) as $intel
    | if   ($amd   | length) > 0 then "\($amd   | max) CPU"
      elif ($intel | length) > 0 then "\($intel | max) CPU"
      else ( [ .. | objects | to_entries[] | select(.key|test("temp[0-9]+_input$")) | .value ]
             | if length > 0 then "\(max) SYS" else "null SYS" end )
      end
  ' <<<"$SENSORS_JSON" 2>/dev/null
)
CPU_TEMP=$(awk -v v="${CPU_TEMP:-null}" 'BEGIN { if (v == "null" || v == "") print "null"; else printf "%.0f", v }')
[ -z "$CPU_TEMP_LABEL" ] && CPU_TEMP_LABEL=SYS

FAN_JSON=$(jq -c '
  [ .. | objects | to_entries[]
    | select(.key|test("fan"; "i"))
    | select(.value|type=="object")
    | { name: .key,
        rpm: ( [ .value | to_entries[] | select(.key|test("_input$")) | .value ] | (.[0] // 0) | floor ) }
    | select(.rpm > 0) ]
' <<<"$SENSORS_JSON" 2>/dev/null)
[ -z "$FAN_JSON" ] && FAN_JSON="[]"

# ---------------------------------------------------------------- GPUs
GPU_JSON="[]"

# AMD (and any other) via the DRM sysfs busy counter.
for dev in /sys/class/drm/card*/device; do
  [ -r "$dev/gpu_busy_percent" ] || continue
  vendor=$(cat "$dev/vendor" 2>/dev/null)
  busy=$(cat "$dev/gpu_busy_percent" 2>/dev/null || echo 0)
  name="GPU"
  temp=null

  # libsensors names a PCI chip "<driver>-pci-<bbdf>" where bbdf = the 16-bit
  # (bus << 8 | devfn) of the device's PCI address. Derive it so the right
  # sensor block is picked on any machine (the address is not fixed).
  pci=$(basename "$(readlink -f "$dev" 2>/dev/null)" 2>/dev/null)   # 0000:06:00.0
  model=$(gpu_model "$pci")
  chip_suffix=""
  if [[ $pci =~ ^[0-9a-fA-F]+:([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$ ]]; then
    chip_suffix=$(printf 'pci-%04x' \
      "$(( (16#${BASH_REMATCH[1]} << 8) | (16#${BASH_REMATCH[2]} << 3) | ${BASH_REMATCH[3]} ))")
  fi

  case "$vendor" in
    0x1002) name="AMD"
      temp=$(jq -r --arg chip "amdgpu-$chip_suffix" '
        ( .[$chip] // ( [ to_entries[] | select(.key|test("^amdgpu")) | .value ] | .[0] ) // {} )
        | [ to_entries[] | select(.key|test("edge|junction|GPU"; "i"))
            | .value | to_entries[] | select(.key|test("_input$")) | .value ] | (.[0] // "null")' \
                   <<<"$SENSORS_JSON" 2>/dev/null) ;;
    0x8086) name="Intel"
      temp=$(jq -r '
        ( [ to_entries[] | select(.key|test("^i915|^xe|^intel")) | .value ] | .[0] // {} )
        | [ to_entries[] | select(.key|test("_input$")) | .value ] | (.[0] // "null")' \
                   <<<"$SENSORS_JSON" 2>/dev/null) ;;
    0x10de) name="NVIDIA" ;;
  esac
  temp=$(awk -v v="${temp:-null}" 'BEGIN { if (v == "null" || v == "") print "null"; else printf "%.0f", v }')
  GPU_JSON=$(jq -c --arg n "$name" --arg m "$model" --argjson b "${busy:-0}" --argjson t "$temp" \
    '. + [{name:$n, model:(if $m == "" then null else $m end), util:$b, temp:$t, mem_pct:null}]' <<<"$GPU_JSON")
done

# NVIDIA only in --full mode: nvidia-smi can spin the dGPU up.
if [ "$FULL" = "1" ] && have nvidia-smi; then
  nv=$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total \
         --format=csv,noheader,nounits 2>/dev/null | head -1)
  nv_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  nv_name=${nv_name# }; nv_name=${nv_name#NVIDIA }   # "NVIDIA GeForce RTX 2060" -> "GeForce RTX 2060"
  if [ -n "$nv" ]; then
    IFS=', ' read -r nv_util nv_temp nv_mu nv_mt <<<"$nv"
    nv_mem_pct=$(awk -v u="${nv_mu:-0}" -v t="${nv_mt:-0}" 'BEGIN { print (t > 0 ? int(100*u/t) : 0) }')
    GPU_JSON=$(jq -c --arg nm "$nv_name" --argjson u "${nv_util:-0}" --argjson tp "${nv_temp:-0}" --argjson mp "$nv_mem_pct" \
      '. + [{name:"NVIDIA", model:(if $nm == "" then null else $nm end), util:$u, temp:$tp, mem_pct:$mp}]' <<<"$GPU_JSON")
  fi
fi

# ---------------------------------------------------------------- disks
DISK_JSON=$(
  df -B1 --output=source,target,pcent,used,size \
     -x tmpfs -x devtmpfs -x efivarfs -x squashfs -x overlay -x ramfs 2>/dev/null \
  | awk 'NR > 1 {
      src = $1; tgt = $2; gsub(/%/, "", $3); pct = $3; used = $4; size = $5
      if (seen[src]++) next            # btrfs subvolumes share a device
      gsub(/,/, "", used); gsub(/,/, "", size)
      printf "%s{\"mount\":\"%s\",\"pct\":%d,\"used_gib\":%.1f,\"total_gib\":%.1f}",
             (n++ ? "," : ""), tgt, pct, used/1073741824, size/1073741824
    }
    END { }' \
  | sed 's/^/[/; s/$/]/'
)
[ "$DISK_JSON" = "[]" ] || [ -n "$DISK_JSON" ] || DISK_JSON="[]"
echo "$DISK_JSON" | jq -e . >/dev/null 2>&1 || DISK_JSON="[]"

# ---------------------------------------------------------------- battery
BAT_JSON=null
for bat in /sys/class/power_supply/BAT*; do
  [ -r "$bat/capacity" ] || continue
  cap=$(cat "$bat/capacity" 2>/dev/null)
  status=$(cat "$bat/status" 2>/dev/null)
  BAT_JSON=$(jq -nc --argjson c "${cap:-0}" --arg s "${status:-Unknown}" '{pct:$c, status:$s}')
  break
done

# ---------------------------------------------------------------- uptime
UPTIME_STR=$(awk '{ s = int($1)
  d = int(s/86400); h = int((s%86400)/3600); m = int((s%3600)/60)
  if (d > 0) printf "%dd %dh", d, h
  else if (h > 0) printf "%dh %dm", h, m
  else printf "%dm", m
}' /proc/uptime)

# ---------------------------------------------------------------- top processes
TOP_CPU_JSON="[]"
TOP_MEM_JSON="[]"
if [ "$FULL" = "1" ]; then
  TOP_CPU_JSON=$(ps -eo comm,%cpu --sort=-%cpu --no-headers 2>/dev/null | head -5 \
    | awk '{ printf "%s{\"name\":\"%s\",\"pct\":%.1f}", (n++ ? "," : ""), $1, $2 }' \
    | sed 's/^/[/; s/$/]/')
  TOP_MEM_JSON=$(ps -eo comm,%mem --sort=-%mem --no-headers 2>/dev/null | head -5 \
    | awk '{ printf "%s{\"name\":\"%s\",\"pct\":%.1f}", (n++ ? "," : ""), $1, $2 }' \
    | sed 's/^/[/; s/$/]/')
  echo "$TOP_CPU_JSON" | jq -e . >/dev/null 2>&1 || TOP_CPU_JSON="[]"
  echo "$TOP_MEM_JSON" | jq -e . >/dev/null 2>&1 || TOP_MEM_JSON="[]"
fi

# ---------------------------------------------------------------- assemble
jq -nc \
  --argjson cpu_pct "${CPU_PCT:-0}" \
  --argjson cpu_cores "${CPU_CORES_JSON:-[]}" \
  --argjson ncpu "${NCPU:-1}" \
  --argjson load "[${LOAD1:-0},${LOAD5:-0},${LOAD15:-0}]" \
  --argjson freq_mhz "${FREQ_MHZ:-null}" \
  --argjson mem_pct "${MEM_PCT:-0}" \
  --argjson mem_used_gib "${MEM_USED_GIB:-0}" \
  --argjson mem_total_gib "${MEM_TOTAL_GIB:-0}" \
  --argjson swap_pct "${SWAP_PCT:-0}" \
  --argjson swap_used_gib "${SWAP_USED_GIB:-0}" \
  --argjson swap_total_gib "${SWAP_TOTAL_GIB:-0}" \
  --argjson temp_c "${CPU_TEMP:-null}" \
  --arg temp_label "${CPU_TEMP_LABEL:-SYS}" \
  --argjson fans "${FAN_JSON:-[]}" \
  --argjson gpus "${GPU_JSON:-[]}" \
  --argjson disks "${DISK_JSON:-[]}" \
  --argjson net "${NET_JSON:-[]}" \
  --argjson battery "${BAT_JSON:-null}" \
  --arg uptime "${UPTIME_STR:-?}" \
  --argjson top_cpu "${TOP_CPU_JSON:-[]}" \
  --argjson top_mem "${TOP_MEM_JSON:-[]}" \
  --argjson full "$FULL" \
  '{
    cpu_pct: $cpu_pct, cpu_cores: $cpu_cores, ncpu: $ncpu, load: $load, freq_mhz: $freq_mhz,
    mem_pct: $mem_pct, mem_used_gib: $mem_used_gib, mem_total_gib: $mem_total_gib,
    swap_pct: $swap_pct, swap_used_gib: $swap_used_gib, swap_total_gib: $swap_total_gib,
    temp_c: $temp_c, temp_label: $temp_label, fans: $fans, gpus: $gpus,
    disks: $disks, net: $net, battery: $battery, uptime: $uptime,
    top_cpu: $top_cpu, top_mem: $top_mem, full: ($full == 1)
  }'
