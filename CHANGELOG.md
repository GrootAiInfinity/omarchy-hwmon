# Changelog

All notable changes to this plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.1] — 2026-09-13

### Changed

- **The Intel GPU scan is capped like every other producer in the backend.** The
  fdinfo snapshots grow one short row per DRM client and engine, and any local
  process can open more descriptors; the rest of this file caps what it reads at
  the point it reads it, and this path did not. The client list is now limited to
  512 descriptors per sample and the snapshot to 256 KiB, and the reader drops a
  row that a cap cut in half rather than reading a missing field as a zero
  counter. Not a vulnerability — a sample is already time-limited and torn down
  by the watchdog — but it is the discipline the rest of the file keeps.

## [1.5.0] — 2026-09-13

Intel GPU utilisation and fan duty cycle, contributed by
[@baylander](https://github.com/baylander), and a core/thread switch for the
CPU grid.

### Added

- **Intel GPU utilisation** (thanks [@baylander](https://github.com/baylander),
  [#1](https://github.com/GrootAiInfinity/omarchy-hwmon/pull/1)). The `xe` and
  `i915` drivers expose no `gpu_busy_percent`, so an Intel iGPU showed no
  utilisation at all. The DRM clients' cycle counters in `/proc/<pid>/fdinfo`
  are snapshotted across the same window the CPU and network deltas already
  use, and the busiest engine is reported as a percentage, keyed by
  `(pdev, client-id, engine)` so a client holding several render fds is not
  counted twice. AMD keeps using `gpu_busy_percent`; NVIDIA keeps using
  `nvidia-smi`; machines with neither pay nothing, because the scan only runs
  when such a card is present.
- **Fan duty cycle** (same contribution). A stopped fan is kept — 0 rpm says
  the fan is off rather than absent — one physical fan exposed through two
  chips is listed once, and the kernel's 0-255 `pwmN` is folded into a
  percentage shown beside the rpm.
- **The CPU grid switches between cores and threads**, cores by default. On an
  SMT machine the thread view is twice the blocks for the same silicon, which
  is more noise than signal unless you are chasing one hot thread. The choice is
  the `cpuView` setting, saved like the bar readout's, and switched from the
  panel with the Cores / Threads buttons above the grid, or over IPC with
  `cores` / `threads` / `toggleCpuView`. `stats` gained `cpu_core_of`, which
  says which physical core each thread sits on.

### Changed

- **The grid adapts to the machine it is on.** A four-core laptop and a
  sixty-four-core workstation are the same widget, so the cells fit themselves
  to the panel rather than the panel growing without end: as many labelled
  cells as the width will carry, up to eight rows of them, and past that a slim
  strip with each row's first number in the margin. Verified by rendering a
  synthetic 64-core / 128-thread machine on a real bar — 128 threads come out as
  seven short rows, and both views draw without a single QML error.
- **The grid blocks are a third of the height and finally carry their number.**
  They were unlabelled vertical bars at `Style.space(40)`; each is now a
  horizontal fill at `Style.space(17)` with the core or thread number on the
  left and its load on the right. With cores as the default, the whole section
  takes well under half the space it did.
- Tidied up on the way in: the fdinfo scan uses `find … -exec +` rather than a
  bare `/proc/*/fdinfo/*` glob, which on a busy machine is tens of thousands of
  arguments and would fail the exec outright; the card's driver is resolved
  without two forks per card per sample; and a fan's label is carried beside its
  key rather than unpacked back out of it, since a label may contain any
  character.

### Tests

- The core map is checked for one entry per thread, whole numbers, as many
  distinct cores as the topology reports, and numbering from 0 with no gaps.
- Fan duty cycle is checked to be absent or a percentage, and rpm to be a whole
  number.

## [1.4.1] — 2026-09-12

Fixes a miscount introduced in 1.3.0: the per-core grid showed one core too many.

### Fixed

- **The CPU core grid drew a seventeenth core on a sixteen-thread machine**, and
  it read 0% forever. 1.3.0 replaced the `grep` over `/proc/stat` with a
  `mapfile` read, which kept the trailing newline that command substitution used
  to strip; the empty field `split()` then returns was treated as another cpu
  line and appended an extra core. The parser now ignores any line that does not
  name a cpu, so it no longer depends on how the snapshot happens to end.
  `ncpu` and `cpu_topology.threads` were always correct — only the grid was
  wrong.

  `tests/test-backend.sh` now checks that the array holds exactly one entry per
  thread, agrees with `ncpu` and with the reported topology, and that every entry
  reads as a percentage. Verified against the previous build, where the new check
  fails with 17 against 16.

## [1.4.0] — 2026-09-12

Removes the plugin's own state file. The readout preference is now kept by the
shell, and the checks that guard this plugin live in the repository.

### Changed

- **The expand/collapse choice is stored in this widget's `shell.json` entry,
  written by the shell.** Omarchy gives a plugin an API for exactly this — the
  same one its own tray and clock widgets use for their runtime state — and the
  shell only lets a plugin write the entry it owns.

  The plugin used to keep a file of its own under `$XDG_STATE_HOME`. Remembering
  one boolean never needed a file, and having one meant validating a path that
  any process running as this user could rearrange between the check and the
  open: two rounds of security review went into getting that right, and 233
  lines of the backend existed to do it. None of it is needed, so none of it is
  left. `hwmon.sh` now writes nothing at all, and `state-read` / `state-write`
  are gone from it.

  Your saved preference moves with you on first use; the now-unused
  `~/.local/state/omarchy-hwmon/` directory can be deleted.

### Added

- **`tests/`.** The properties that reviews have turned up are pinned as
  checks: a wedged sample and the helpers under it are
  torn down while the shell is left alone; a pid that is not ours is refused
  rather than signalled; a planted binary earlier in `PATH` changes nothing; a
  hostile process name cannot break the JSON; the backend creates no files; and
  the repository keeps the shape the marketplace's automated baseline expects.
  `tests/run-tests.sh` runs them all, and the one that needs a real Quickshell
  skips itself without one.

## [1.3.0] — 2026-09-12

Closes the two findings from the third marketplace security review, and takes
the temperature path off `lm_sensors`, which halves what a sample costs.

### Security

- **The state directory is now held as a descriptor, not re-resolved as a
  path.** Both directions validated the directory and then reached back through
  it by name for every later step — the create, the rename, the read — so a
  same-user process that exchanged an intermediate directory after the check
  had the write redirected into a directory of its own choosing, and the read
  answered from one. The descriptor-identity check added in 1.2.1 covered only
  the final entry, not the components above it.

  The directory is now walked one component at a time from the filesystem root:
  each component is lstat'd, opened, and fstat'd through its own descriptor,
  and the device/inode pair has to match across the open, so a component
  swapped for a symlink or for another directory is rejected rather than
  followed. Ownership, type and permissions are asked of that descriptor.
  Everything afterwards addresses the entry as `/proc/self/fd/9/expanded`,
  which is `openat(9, "expanded")` — the create, the read, the rename, the
  unlink and the fsync all land in the object the walk validated, with no path
  left above it to re-traverse. Reproduced before fixing, with a one-second
  window at the check-to-use gap: the old code wrote the state into the
  attacker's directory and read back the attacker's value; the new code does
  neither, and lands in the directory it validated even when the whole path is
  rearranged mid-operation.

- **Directory permissions were only half-checked.** The "group- or
  other-writable" test matched the last character of the mode, so a state
  directory that was group-writable but not world-writable passed it.

- **Escalation no longer depends on what the QML side believes.** The watchdog
  recorded a pid, asked the process to stop, and three seconds later the
  escalation re-checked Quickshell's `running` flag before acting. The flag
  does stay true while a process ignores SIGTERM (measured: the old path did
  fire and did kill the group), but it goes false the moment the sample itself
  exits — and its helpers do not exit with it. A wedged `nvidia-smi` under a
  sample that died on SIGTERM was left running indefinitely, holding the pipe.

  The escalation is now keyed on the recorded pid alone and runs whatever this
  side believes. What it does about that pid is `hwmon.sh reap`'s decision:
  the target must still be its own process group and session leader, must have
  been running at least as long as the deadline that was waiting on it (so a
  recycled pid is refused, not killed), must still be running this script, and
  must not be our own group. If the leader has already gone, the group is swept
  anyway — but only while nothing has taken the leader's pid, and only for
  members that predate the deadline. Between the group's TERM and its KILL the
  group is re-examined, and a member newer than the deadline stops the teardown
  rather than being caught in it.

- **The state operations now have a whole-operation ceiling.** Every helper they
  run was already time-limited, but opening a name is not a helper: a FIFO left
  at one of these paths blocks in the kernel. `state-read` / `state-write`
  re-exec themselves once under `timeout`, and the widget applies a deadline of
  its own on top, with the same reaper behind it.

### Changed

- **Temperatures and fans come from `/sys/class/hwmon` directly; `lm_sensors` is
  no longer a dependency.** `sensors -j` cost 75–110 ms per sample — about half
  the work in a sample that runs every 1.5–3 seconds — and brought with it a
  256 KB buffer, three `jq` passes to dig the values back out, and a chip name
  derived from a PCI address, which is what silently broke GPU temperature on
  this hardware once before. Each GPU's temperature now comes from that card's
  own `hwmon` directory, so there is no name to derive and no way to attribute
  one card's reading to another. The values are identical; the CPU sensor is
  still `k10temp` Tdie/Tctl/Tccd, then `coretemp` "Package id", then the hottest
  sensor on the machine labelled `SYS`.
- **A sample costs about half of what it did.** The helpers called forty-odd
  times per sample (`num`, `squish`, rounding) were an `awk` each and are now
  bash; `/proc/stat` is read with `mapfile` rather than `grep` or a `read` loop
  (bash's `read` goes to the kernel a byte at a time, which on a large `/proc`
  file costs more than everything else in the sample together); `nproc` and one
  `uname` are gone, the thread count coming from the topology pass that already
  reads `/proc/cpuinfo`; and the expensive sensors — vendor WMI chips and
  `acpitz`, which evaluate ACPI methods — are only read when there is no CPU
  package sensor to ask instead. Measured on this machine: 0.74 s → 0.51 s of
  wall clock per light sample, 0.40 s → 0.23 s of CPU.
- **Fan speeds are collected only while the panel is open**, like the storage
  list and the top processes, since that is the only place they are shown.
- `squish` also flattens embedded newlines now, which the tab-separated rows it
  feeds have always assumed.

## [1.2.3] — 2026-09-11

Stops a read from being refused because the widget itself was writing. No
change to what the widget shows.

### Fixed

- **A read racing the widget's own write returned nothing.** The 1.2.1 check
  refuses a file whose inode changed across the open, which is what an attacker
  swapping in a symlink looks like — but it is also what the widget's own
  `rename` looks like when the toggle is saved at that moment. About 3% of reads
  taken during a write were refused, and at startup a refused read silently
  drops the saved toggle in favour of the manifest default. The read now retries
  up to five times. Each attempt is validated from scratch on its own
  descriptor, so a swapped object is still never read: retrying only lets a
  legitimate read finish, and an attacker swapping forever can deny the read but
  never redirect it.

## [1.2.2] — 2026-09-11

Cleans up after an interrupted state-file write. No change to what the widget
shows.

### Fixed

- **An interrupted write left its temporary file behind.** 1.2.1 gave the
  temporary file an unguessable name, which removed the old predictable one but
  also removed what made the leftovers self-limiting: a write killed between
  creating that file and renaming it now left a new one each time, and the
  widget's `Process` objects are torn down, children and all, every time the
  plugin reloads. Writes now clean up on exit and on a signal, and sweep any
  leftover older than a minute — old enough that no live writer can still own
  it — so a concurrent write is never disturbed.
- **A terminated write could log an error.** The cleanup on SIGTERM removed the
  temporary file and then returned to where it interrupted, which went on to
  `mv` the file it had just deleted and printed the failure to stderr. The
  signal handlers exit after cleaning up.

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

[1.2.3]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.2.3
[1.2.2]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.2.2
[1.2.1]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.2.1
[1.2.0]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.2.0
[1.1.0]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.1.0
[1.0.0]: https://github.com/GrootAiInfinity/omarchy-hwmon/releases/tag/v1.0.0
