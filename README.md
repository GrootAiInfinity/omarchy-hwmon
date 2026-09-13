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
  - CPU usage, current / max frequency, load average, and a numbered grid of
    per-core blocks — switchable to one block per thread, cores by default
  - Memory and swap
  - Thermals and fan speeds (a stopped fan included, with its PWM duty cycle
    where the chip exposes one)
  - Per-GPU utilisation meters, each labelled with its model name (e.g.
    `Radeon RX 6600`, `GeForce RTX 3060`, `Arc B390`) — AMD via the
    `gpu_busy_percent` DRM counter, Intel's `xe`/`i915` via the DRM clients'
    `/proc/<pid>/fdinfo` cycle counters, NVIDIA via `nvidia-smi`
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
- coreutils / procps / util-linux (`df`, `ps`, `uname`, `timeout`, `setsid`),
  all already present on any Omarchy install

Optional, each only enabling its own row:

- `nvidia-smi` — NVIDIA utilisation, temperature and VRAM
- `pciutils` (`lspci`) — friendly GPU model names; without it the meter falls
  back to the bare vendor label

Nothing else is required: every other value comes from `/proc` and `/sys`.
Temperatures and fan speeds are read from the kernel's `hwmon` interface
directly, so `lm_sensors` is no longer needed (it was required up to v1.2.3).

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
plugin writes nothing outside it, so there is nothing else to clean up. (Up to
v1.3.0 it kept the remembered readout choice in `~/.local/state/omarchy-hwmon/`;
if you used one of those versions, that directory is now unused and safe to
delete.)

## Configuration

Two settings, exposed in the manifest and settable per bar entry in
`~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.grootaiinfinity.hwmon", "expanded": true, "cpuView": "cores" }
```

`expanded` is the bar readout; `cpuView` is `cores` or `threads` and decides
whether the grid under the CPU meter shows one block per physical core or one
per thread. Both are also switched from the widget itself — the readout by
right-click or scroll, the grid by the Cores / Threads buttons above it.

Changing either at runtime writes it back to that same entry: the shell does
the write, the way it does for its own tray and clock widgets. There is no
second place these preferences live.

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
  `/proc/uptime`, DRM clients' `/proc/<pid>/fdinfo/*` (Intel GPU busyness),
  `/etc/os-release` (parsed, never sourced), and under `/sys`:
  `class/hwmon/*` (temperatures and fans), `class/net/*/statistics`,
  `class/drm/card*/device`, `class/power_supply/BAT*`, `block/*`,
  `devices/system/cpu/*/cpufreq`, `devices/virtual/dmi/id`.
- **Runs:** `jq`, `df`, `ps`, `uname`, `awk`, `grep`, `timeout` and `setsid`,
  and — only while the panel is open — `nvidia-smi` and `lspci`.
- **Writes:** nothing. The one preference it remembers is stored by the shell in
  this widget's own entry in `shell.json`, through the API Omarchy gives a
  plugin for exactly that; the shell only lets a plugin write the entry it owns.
  The backend touches no file at all.
- **Values that come from outside** — process names, mount points, device and
  GPU model strings — are encoded as JSON by `jq` and rendered as
  `Text.PlainText`, so they cannot break the output or promote themselves to
  markup in the panel. Each producer also has a byte cap, so no helper can grow
  the shell's memory without bound.
- **Nothing is resolved through your PATH.** The backend is launched by
  absolute path with an empty environment, and resets `PATH` to root-owned
  system directories before calling any helper, so a binary planted earlier in
  your `PATH` cannot stand in for `jq`, `df` or `nvidia-smi`.
- **There is no file of its own to attack.** Earlier versions kept the readout
  preference in `$XDG_STATE_HOME`, which meant validating a path that any
  process running as this user could rearrange between the check and the open.
  Handing that one boolean to the shell removes the question entirely.
- **A sample that hangs is taken apart, not trusted to stop.** Each one runs in
  its own process group under a deadline; if it ignores the request to stop, the
  group is torn down — after the backend re-checks from `/proc` that the process
  is still the leader of a group of its own, old enough to be the one that was
  being waited on, and still running this script. Helpers that outlive their
  parent are swept the same way.

## Troubleshooting

**The bar shows `--`.** The backend did not produce a sample. Run it by hand
(see [Scripting](#scripting)); it prints the reason on stderr, or
`{"error":"…"}` when a required tool such as `jq` is missing. The widget
recovers on its own once samples return.

**A `SYS` label instead of `CPU`.** This machine exposes no `k10temp` (AMD) or
`coretemp` (Intel) package sensor under `/sys/class/hwmon`, so the hottest
sensor on the machine is shown instead and labelled `SYS`. Loading the driver
for your platform's sensor chip (`sensors-detect` from `lm_sensors` can identify
it) gives the kernel more to expose; the plugin then picks it up on its own.

**A GPU shows no utilisation.** It is neither AMD (which exposes
`gpu_busy_percent`), an Intel `xe`/`i915` card (whose DRM fdinfo cycle counters
are read), nor an NVIDIA card reachable through `nvidia-smi`. Temperature and
model name may still appear.

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

## Checks

The behaviour this plugin is expected to hold to is pinned by tests rather than
by prose — that a wedged sample and the helpers under it are actually torn down,
that a planted binary earlier in `PATH` changes nothing, that a hostile process
name cannot break the JSON, that the backend writes no files, and that the
repository keeps the shape the marketplace baseline expects:

```sh
tests/run-tests.sh
```

They run on any Linux box; the one that drives a real Quickshell skips itself
where none is installed.

## Contributing

Issues and pull requests are welcome at
<https://github.com/GrootAiInfinity/omarchy-hwmon>. Keep `hwmon.sh` free of
machine-specific paths, route anything that ends up in the JSON through `jq`
rather than hand-written string formatting, and add a check under `tests/` for
anything that would be a bug if it came back.

## License

MIT — see [LICENSE](LICENSE).
