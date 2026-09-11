# Changelog

All notable changes to this plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.1] — 2026-09-11

Closes a time-of-check/time-of-use race in the state file, from the follow-up
marketplace security review of 1.2.0
([#6263](https://github.com/omacom/omarchy-plugin-marketplace/issues/6263)).
No change to what the widget shows.

### Security

- **The state file is validated on the descriptor, not on the path.** 1.2.0
  asked whether the path was a symlink, a regular file, ours, and small enough,
  and then opened that path again — so an entry exchanged for a symlink in
  between was checked as one object and read as another, past both the identity
  check and the two-byte cap. `state-read` now lstats the name, opens it, and
  fstats the descriptor through `/dev/fd`: unless the device and inode still
  match, the read is refused, and type, owner and size are settled against the
  descriptor itself. Against an attacker swapping the path in a loop, 1.2.0
  returned the planted file's contents in 51 of 600 reads; this returns it in
  none.
- **The read cannot hang.** It runs in a child under a two-second limit,
  because opening the path is the one step that blocks — a FIFO left there
  waits for a writer that never comes, and would have held the widget's single
  in-flight sample slot indefinitely.
- **The temporary file is created exclusively and never reopened by name.**
  1.2.0 removed a predictable `.expanded.$$` and then opened that name with
  shell redirection, which a concurrent replacement could redirect. The name is
  now 64 bits of `/dev/urandom`, and one `O_CREAT|O_EXCL|O_NOFOLLOW` open
  writes and fsyncs the value through that same descriptor. The directory is
  re-checked immediately before `rename(2)` — which replaces the destination
  without following it, so the old "remove the target first" step, itself a
  check-then-open race, is gone — and the directory is fsynced afterwards.

## [1.2.0] — 2026-09-11

Supply-chain and resource-exhaustion hardening, from a marketplace security
review of 1.1.0 ([#6263](https://github.com/omacom/omarchy-plugin-marketplace/issues/6263)).
No change to what the widget shows.

### Security

- **Nothing is resolved through the caller's PATH any more.** The backend used
  an `env`-style shebang and called `jq`, `sensors`, `df`, `ps`, `nvidia-smi`
  and `lspci` by bare name, so a binary planted earlier in the shell process's
  PATH would have been executed every 1.5-3 seconds inside `omarchy-shell`.
  The interpreter is now `/bin/bash` by absolute path, the script resets PATH
  to root-owned system directories before any helper runs, and the widget
  launches it through `/usr/bin/env -i` with an empty environment — which also
  drops `BASH_ENV`, `LD_PRELOAD` and anything else inherited from the session.
- **The state file is validated before it is read.** It was read through the
  QML file API, which cannot ask what a path actually is, so a symlink left at
  `~/.local/state/omarchy-hwmon/expanded` would have been followed. Both
  directions now go through `hwmon.sh state-read` / `state-write`, which refuse
  symlinks, require a regular file owned by the user, cap it at two bytes, and
  refuse a state directory that is not a private directory the user owns.
  Writes replace the target and rename into place.

### Fixed

- **Unbounded buffering of helper output.** `sensors -j` and `nvidia-smi` were
  captured whole into shell variables, and the widget's `StdioCollector`
  buffers a sample's entire stdout with no limit of its own. Each producer now
  has a byte cap applied where it is produced (256 KiB for `sensors`, 4 KiB for
  `nvidia-smi`, and caps on `lspci`, `df`, `ps` and the script's own output).
- **A sample that ignored SIGTERM was never killed.** The watchdog only set
  `running = false`, which is a request; Quickshell's `Process` has no signal
  method, so a helper stuck in a driver call sat there holding memory. Samples
  now run under `setsid` in their own process group, every external helper runs
  under `timeout -s KILL`, and a sample that is still alive 3 s after the
  terminate request has its whole process group killed — verified against a
  backend that traps SIGTERM, including a child process it spawned.

### Changed

- The expand/collapse choice no longer live-syncs between bars on separate
  monitors; it is read once at startup. Validating the file matters more than
  the sync did.
- New runtime dependency: `util-linux` (for `setsid`), part of the Arch `base`
  group and already present on any Omarchy install.

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

[1.2.1]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.2.1
[1.2.0]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.2.0
[1.1.0]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.1.0
[1.0.0]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.0.0
