# Hardware Monitor (omarchy-hwmon)

A hardware-monitor widget for the [Omarchy](https://omarchy.org/) status bar
(Quickshell). It shows a live CPU / temperature readout in the bar and opens a
detailed system panel on click.

Plugin id: `io.github.grootaiinfinity.hwmon` · Kind: `bar-widget` · License: MIT

![the widget in the bar](docs/bar.png)

![the CPU section of the detail panel](docs/panel.png)

The screenshots show the bar readout and one section of the detail panel. The
other sections — system summary, thermals and fans, GPUs, storage, disks,
network, top processes, battery — are left out on purpose: a screenshot of them
is a photograph of the author's hardware and running software, not information
about the plugin. The full list of what the panel shows is below.

## Features

- **Compact bar readout:** `CPU%` + package temperature.
- **Right-click / scroll** toggles an expanded readout: adds `MEM%`, `GPU%`,
  `BAT%`. The choice is remembered across restarts.
- **Left-click** opens the detail panel:
  - System summary: machine model, CPU model, core / thread / socket count,
    distro, kernel, architecture
  - CPU usage, current / max frequency, load average, and a per-core bar grid
  - Memory and swap
  - Thermals and fan speeds
  - Per-GPU utilisation meters, each labelled with its model name (e.g.
    `Radeon RX 6600`, `GeForce RTX 3060`) — AMD/Intel via the
    `gpu_busy_percent` DRM counter, NVIDIA via `nvidia-smi`
  - Storage devices: model name, bus (NVMe / SATA / USB), capacity, temperature
  - Disk usage per mount (with the backing device)
  - Live network throughput per interface
  - Top processes by CPU and by RAM
  - Battery level and charge status
- Polls every 3 s (1.5 s while the panel is open).
- NVIDIA is only queried while the panel is open, so the background poll never
  wakes a dGPU that is asleep.
- If the backend cannot run or stops responding, the bar shows `--` and the
  panel says why, instead of displaying a confident `0%`.

## Requirements

- Omarchy (Quattro) with the Quickshell-based bar
- `jq` — the backend builds its JSON with it
- `lm_sensors` (`sensors`) — temperatures and fan speeds
- coreutils / procps (`df`, `ps`, `nproc`, `uname`), which Omarchy already has

Optional, each only enabling its own row:

- `nvidia-smi` — NVIDIA utilisation, temperature and VRAM
- `pciutils` (`lspci`) — friendly GPU model names; without it the meter falls
  back to the bare vendor label

Nothing else is required: every other value comes from `/proc` and `/sys`.

## Install

```sh
omarchy plugin add https://github.com/GrootAiInfinity/omarchy-hwmon.git --enable
```

This adds the widget to the right side of the bar.

Update:

```sh
omarchy plugin update io.github.grootaiinfinity.hwmon
```

Remove:

```sh
omarchy plugin remove io.github.grootaiinfinity.hwmon
```

Removal takes the widget out of the bar and deletes the plugin directory. The
one file the plugin writes outside it is the remembered expand/collapse choice:

```sh
rm -rf ~/.local/state/omarchy-hwmon
```

## Configuration

One setting, `expanded`, exposed in the manifest and settable per bar entry in
`~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.grootaiinfinity.hwmon", "expanded": true }
```

It is the **initial** value only. Once you toggle the readout at runtime
(right-click or scroll) that choice is saved to
`~/.local/state/omarchy-hwmon/expanded` and wins from then on; delete that file
to go back to the configured default.

### Scripting

The widget answers on its own IPC target, so keybindings and scripts can drive
it:

```sh
omarchy-shell io.github.grootaiinfinity.hwmon toggle           # detail panel
omarchy-shell io.github.grootaiinfinity.hwmon open
omarchy-shell io.github.grootaiinfinity.hwmon close
omarchy-shell io.github.grootaiinfinity.hwmon expand           # bar readout
omarchy-shell io.github.grootaiinfinity.hwmon collapse
omarchy-shell io.github.grootaiinfinity.hwmon toggleExpanded
```

The backend can also be run on its own — it prints one line of JSON:

```sh
~/.config/omarchy/plugins/io.github.grootaiinfinity.hwmon/hwmon.sh stats
~/.config/omarchy/plugins/io.github.grootaiinfinity.hwmon/hwmon.sh stats --full
```

## What it reads, what it runs

The plugin is read-only with respect to your system.

- **Privileges:** it runs entirely as your user and never asks to be elevated.
  It installs no service, no unit, no policy file and no dispatcher hook.
- **Network:** none. The plugin makes no outbound request of any kind.
- **Reads:** `/proc/stat`, `/proc/meminfo`, `/proc/loadavg`, `/proc/cpuinfo`,
  `/proc/uptime`, `/etc/os-release` (parsed, never sourced), and under `/sys`:
  `class/net/*/statistics`, `class/drm/card*/device`, `class/power_supply/BAT*`,
  `block/*`, `devices/system/cpu/*/cpufreq`, `devices/virtual/dmi/id`.
- **Runs:** `jq`, `sensors`, `df`, `ps`, `nproc`, `uname`, `awk`/`sed`/`grep`,
  and — only while the panel is open — `nvidia-smi` and `lspci`.
- **Writes:** one file, `~/.local/state/omarchy-hwmon/expanded`, containing `0`
  or `1`. It never edits `shell.json` or any other file you own.
- **Values that come from outside** — process names, mount points, device and
  GPU model strings — are encoded as JSON by `jq` and rendered as
  `Text.PlainText`, so they cannot break the output or promote themselves to
  markup in the panel.

## Troubleshooting

**The bar shows `--`.** The backend did not produce a sample. Run it by hand
(see [Scripting](#scripting)); it prints the reason on stderr, or
`{"error":"…"}` when a required tool such as `jq` is missing. The widget
recovers on its own once samples return.

**No temperature, or a `SYS` label instead of `CPU`.** `lm_sensors` is missing,
or this machine exposes no `k10temp`/`coretemp` chip; the hottest generic sensor
is then shown and labelled `SYS`. Running `sensors-detect` (from `lm_sensors`)
as root can help the kernel find more chips.

**A GPU shows no utilisation.** It exposes no `gpu_busy_percent` counter and is
not an NVIDIA card reachable through `nvidia-smi`. Temperature and model name
may still appear.

**The widget disappeared after an update.** `omarchy update` / `omarchy refresh
shell` can rewrite `shell.json` and drop the layout entry — the plugin files
survive. Re-enable it:

```sh
omarchy plugin enable io.github.grootaiinfinity.hwmon
omarchy restart shell
```

**Shell logs:** `/run/user/$UID/quickshell/by-id/*/log.log`.

## Compatibility

Built and tested against Omarchy Quattro (4.x) with Quickshell 0.3.x on
Arch Linux, x86_64, on AMD + NVIDIA hybrid graphics. Nothing is hard-coded to
this machine: CPU, GPU, sensor chips, disks, network interfaces and battery are
all discovered at runtime, and every field degrades to `null` when the kernel
does not expose it.

## Marketplace

- Category: `Hardware`
- Tags: `bar`, `quickshell`, `system`

## Contributing

Issues and pull requests are welcome at
<https://github.com/GrootAiInfinity/omarchy-hwmon>. Keep `hwmon.sh` free of
machine-specific paths, and route anything that ends up in the JSON through
`jq` rather than hand-written string formatting.

## License

MIT — see [LICENSE](LICENSE).
