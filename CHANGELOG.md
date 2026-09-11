# Changelog

All notable changes to this plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] — 2026-09-11

Hardening and correctness pass before marketplace submission. No change to what
the widget shows when everything is healthy.

### Security

- **No shell string interpolation in the QML.** The expand/collapse state file
  was written and read by splicing its path into a `bash -c` command line
  inside single quotes. The path is built from `$XDG_STATE_HOME` / `$HOME`, so a
  single quote in either variable ended the quoting and the remainder ran as
  commands under the shell process. The state file is now read and written
  through Quickshell's `FileView`, which takes the path as data; the one
  remaining process call (`mkdir` on first run) passes it as a separate
  argument rather than as command text.
- **`/etc/os-release` is parsed, not sourced.** The distro name was read by
  sourcing the file, which executes it. It is now parsed with `awk`, so the
  backend executes no file it only means to read.

### Fixed

- **A process name containing `"` or `\` wiped out the whole top-process
  list.** Names were formatted into JSON by hand, so any process — and any
  local user can start one called `a"b` — produced invalid JSON and the entire
  CPU/RAM top-five silently collapsed to empty. Process rows are now built by
  `jq`, which escapes them.
- **Process names containing spaces were cut short** ("Web Content" showed as
  "Web"); the percentage is now anchored to the end of the line so the full
  name survives.
- **A mount point containing a space reported the wrong numbers.** `df` output
  was split on whitespace, so a USB drive mounted at `/run/media/<user>/My
  Drive` shifted every column: the name was truncated and its size, usage and
  percentage were read from the wrong fields. The mount point is now captured
  to end of line.
- **`nvidia-smi` answering `[N/A]` removed every GPU from the panel**, not just
  the unavailable field. Each NVIDIA counter now degrades to `null` on its own.
- **A wedged backend froze the readout for the rest of the session.** Only one
  sample may be in flight at a time, and a hung `nvidia-smi` or sensor never
  released the slot. A watchdog now stops a sample that overruns, and a readout
  with no fresh data for 12 s shows `--` and explains itself in the panel and
  tooltip, instead of displaying a confident `0%`.
- **The saved expand/collapse choice could be overwritten at startup** by the
  manifest default, depending on which of the two arrived first. Resolution is
  now deterministic: a saved choice always wins, the manifest setting applies
  only when nothing is saved yet.
- Any unreadable sensor, sysfs or `nvidia-smi` value now falls back to `null`
  for that field alone; previously a non-numeric read could abort `jq` and drop
  a whole section (GPUs, storage, disks).

### Added

- IPC control for the bar readout, alongside the existing panel commands:
  `omarchy-shell io.github.grootaiinfinity.hwmon expand | collapse |
  toggleExpanded`.
- `hwmon.sh --help`, and a clear error (exit 2) for unrecognised arguments.
- `hwmon.sh` reports a missing `jq` in-band as `{"error":"…"}`, which the widget
  shows, instead of failing silently.
- README sections covering exactly what the plugin reads, runs and writes;
  troubleshooting; scripting; and compatibility.

### Changed

- Screenshots no longer show this machine. `preview.png` and `docs/panel.png`
  were cropped to the bar readout and the CPU/memory section; the panel
  sections that name the host, CPU, GPUs, drives, mounts, network interface and
  running processes are gone from both, and PNG metadata chunks are stripped.
- The backend runs with `LC_ALL=C`, so a non-English locale cannot change the
  decimal separator or the wording of the tool output it parses.
- Fewer subprocesses per sample: each of the network, GPU, storage, disk and
  process sections is now converted to JSON in a single `jq` call instead of
  one per item.
- The saved toggle moved from `~/.local/state/omarchy-hwmon.expanded` to
  `~/.local/state/omarchy-hwmon/expanded`. An existing file at the old path is
  ignored, so the bar starts from the configured default once; delete it at
  your convenience.
- Dropped the `$schema` key from `manifest.json`: it pointed at a URL that does
  not exist.

## [1.0.0] — 2026-09-09

First packaged release as an Omarchy plugin.

- Bar readout (CPU%, temperature; optionally memory, GPU, battery) and a detail
  panel covering system summary, CPU cores, memory, swap, thermals and fans,
  GPUs, storage devices, disk usage, network throughput, top processes and
  battery.
- GPU model names resolved from `lspci` / `nvidia-smi`; GPU sensor chip derived
  from each card's PCI address rather than hard-coded.
- Plugin id `io.github.grootaiinfinity.hwmon`.

[1.1.0]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.1.0
[1.0.0]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.0.0
