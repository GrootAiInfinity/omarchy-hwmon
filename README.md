# omarchy-hwmon

A hardware-monitor widget for the [Omarchy](https://omarchy.org/) status bar
(Quickshell). Shows a live CPU / temperature readout in the bar and opens a
detailed system panel on click.

![panel](docs/panel.png)

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
    `Radeon Vega Series`, `GeForce RTX 2060`) — AMD iGPU via `gpu_busy_percent`
    sysfs, NVIDIA via `nvidia-smi`
  - Storage devices: model name, bus (NVMe / SATA / USB), capacity, temperature
  - Disk usage per mount (with the backing device)
  - Live network throughput per interface
  - Top processes by CPU and by RAM
  - Battery level and charge status
- Polls every 3 s (1.5 s while the panel is open).
- NVIDIA is only queried while the panel is open, so the background poll never
  wakes a dGPU that is asleep.

## Requirements

- Omarchy shell (Quickshell-based bar)
- `jq`, `lm_sensors` (`sensors`), coreutils (`free`, `df`, `nproc`, `ps`)
- Optional: `nvidia-smi` for NVIDIA GPU stats; `pciutils` (`lspci`) for GPU
  model names

## Install

```sh
omarchy plugin add https://github.com/GrootAiInfinity/omarchy-hwmon.git --enable
```

Adds the widget to the right side of the bar. Remove it with
`omarchy plugin remove io.github.grootaiinfinity.hwmon`, update with
`omarchy plugin update io.github.grootaiinfinity.hwmon`.

### Optional: start expanded

```sh
omarchy plugin enable io.github.grootaiinfinity.hwmon   # if not already
```

then set `expanded` on the `io.github.grootaiinfinity.hwmon` entry in
`~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.grootaiinfinity.hwmon", "expanded": true }
```

(also toggled any time with right-click / scroll on the widget).

## Notes

- No machine-specific values are hard-coded — every detail is discovered at
  runtime, so the plugin works as-is on any machine it is installed on:
  - CPU model / topology from `/proc/cpuinfo`, frequencies from
    `/sys/devices/system/cpu/*/cpufreq`
  - machine model / vendor from DMI (`/sys/devices/virtual/dmi/id`), distro from
    `/etc/os-release`, kernel + arch from `uname`
  - storage devices enumerated from `/sys/block` (model, rotational flag,
    capacity, per-drive `hwmon` temperature); bus inferred from the device path
  - `hwmon.qml` finds `hwmon.sh` via `Qt.resolvedUrl(".")`; the GPU sensor block
    is matched by deriving the libsensors chip name (`<driver>-pci-<bbdf>`) from
    each DRM card's PCI address, with a fallback to the first `amdgpu*` /
    `i915*` chip.
- GPU coverage: AMD and Intel utilisation via the `gpu_busy_percent` DRM sysfs
  counter (temp via `lm_sensors`); NVIDIA via `nvidia-smi` (panel-open only).
  A GPU with no `gpu_busy_percent` and no `nvidia-smi` shows no utilisation.
- GPU model names come from `lspci` (marketing name in `[brackets]`, first
  variant of an `A / B` pair) and `nvidia-smi --query-gpu=name`; without
  `lspci` the meter falls back to the bare vendor label.
- `omarchy update` / `omarchy refresh shell` rewrites `shell.json` and drops the
  `hwmon` layout entry (the widget files survive). Re-run
  `omarchy plugin enable io.github.grootaiinfinity.hwmon` and `omarchy restart shell`.

## License

MIT
