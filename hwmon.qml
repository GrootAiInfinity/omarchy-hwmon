import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Hardware monitor bar module.
//   Left click  - open the detailed panel (CPU cores, GPUs, disks, net, procs)
//   Right click - toggle the compact / expanded readout in the bar itself
//   Scroll      - same toggle
// Backend: hwmon.sh, bundled alongside this file in the plugin folder.
Panel {
  id: root
  moduleName: "io.github.grootaiinfinity.hwmon"
  ipcTarget: "io.github.grootaiinfinity.hwmon"
  // The base Panel would install its own handler for the same target, and a
  // target only gets one; own it here so the bar readout is scriptable too.
  manageIpc: false

  // Resolve the bundled backend script relative to this plugin's own folder,
  // wherever `omarchy plugin add` installed it.
  readonly property string pluginDir: {
    var dir = String(Qt.resolvedUrl("."))
    return dir.replace(/^file:\/\//, "").replace(/\/$/, "")
  }
  readonly property string script: pluginDir + "/hwmon.sh"

  // Every helper is launched through an absolute interpreter with an empty
  // environment and a PATH of root-owned system directories only. Nothing is
  // resolved through the shell process's own PATH, so a binary planted ahead of
  // /usr/bin in it cannot stand in for the backend or anything the backend
  // calls; BASH_ENV, LD_PRELOAD and friends are dropped with the rest of the
  // environment. setsid puts the sample in its own process group so a stuck
  // one can be killed whole without touching the shell's group.
  function launch(argv) {
    var pre = ["/usr/bin/setsid", "/usr/bin/env", "-i",
               "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
               "LC_ALL=C"]
    var home = Quickshell.env("HOME") || ""
    if (home) pre.push("HOME=" + home)
    var xdg = Quickshell.env("XDG_STATE_HOME") || ""
    if (xdg) pre.push("XDG_STATE_HOME=" + xdg)
    return pre.concat(argv)
  }

  property var stats: ({})

  // The bar readout's expand/collapse choice is simply this widget's own
  // setting: one value, read here and written by the shell. `settings` is
  // injected a tick after Component.onCompleted, so this starts at the manifest
  // default and follows the saved value the moment it arrives - no resolving,
  // no ordering to get wrong.
  readonly property bool expanded: !!root.setting("expanded", false)

  // The shell injects this into a plugin root that declares it; the bar carries
  // the same handle for widgets that reach it that way.
  property var shell: null
  readonly property var shellApi: root.shell || (root.bar ? root.bar.shell : null)

  // Cores or threads in the grid below the CPU meter. Cores by default: on an
  // SMT machine the thread view is twice the blocks for the same silicon, which
  // is more noise than signal unless you are chasing one hot thread. Saved with
  // the rest of this widget's settings, so the choice survives a restart.
  readonly property string cpuView: root.setting("cpuView", "cores") === "threads" ? "threads" : "cores"

  function setCpuView(v) {
    if (v !== "cores" && v !== "threads" || root.cpuView === v) return
    root.save("cpuView", v)
  }

  // [{ label, pct }] for the grid. Threads come straight from the backend;
  // cores average the threads the kernel says sit on each one. Without a
  // topology map (some VMs, some ARM) there is nothing to fold, so the thread
  // view is all there is.
  readonly property var cpuCells: {
    var t = root.stats.cpu_cores || []
    var threads = t.map(function (v, i) { return { label: String(i), pct: Number(v) || 0 } })
    if (t.length === 0 || root.cpuView === "threads") return threads

    var map = root.stats.cpu_core_of || []
    if (map.length !== t.length) return threads

    var sum = {}, n = {}
    for (var i = 0; i < t.length; i++) {
      var c = Number(map[i])
      sum[c] = (sum[c] || 0) + (Number(t[i]) || 0)
      n[c] = (n[c] || 0) + 1
    }
    var out = []
    for (var k in sum) out.push({ key: Number(k), label: String(k), pct: sum[k] / n[k] })
    out.sort(function (a, b) { return a.key - b.key })
    return out
  }

  readonly property int cpuPct: Math.round(Number(stats.cpu_pct) || 0)
  readonly property int memPct: Math.round(Number(stats.mem_pct) || 0)
  readonly property var tempC: (stats.temp_c === null || stats.temp_c === undefined) ? null : Math.round(stats.temp_c)
  readonly property var gpus: stats.gpus || []
  readonly property var disks: stats.disks || []
  readonly property var netList: stats.net || []
  readonly property var fans: stats.fans || []
  readonly property var battery: stats.battery || null
  readonly property real gpuPct: gpus.length > 0 ? Math.round(Number(gpus[0].util) || 0) : 0

  // The backend reports its own failures in-band (no jq, for example) rather
  // than leaving the widget showing a confident 0%.
  readonly property string statsError: (stats && stats.error) ? String(stats.error) : ""
  // Epoch ms of the last sample that parsed. Staleness - rather than the exit
  // code - is what the readout is judged on: a backend that is missing, has
  // crashed, is wedged, or prints something unreadable all look the same from
  // here, and all of them mean the numbers on screen are no longer current.
  property double lastSampleMs: 0
  property bool stalled: false
  readonly property bool degraded: statsError !== "" || stalled
  readonly property int staleAfterMs: 12000

  // Hottest thing worth alarming about, for the bar glyph tint.
  readonly property bool alarm: !degraded && (cpuPct >= 90 || memPct >= 90 || (tempC !== null && tempC >= 88))

  readonly property color fg: Color.popups.text

  readonly property string tooltipText: {
    var lines = []
    if (degraded) {
      lines.push(statsError !== "" ? statsError : "hwmon: the last sample did not finish")
      lines.push("")
    }
    lines.push("CPU  " + cpuPct + "%" + (stats.freq_mhz ? "  ·  " + fmtGhz(stats.freq_mhz) : "")
               + (stats.load ? "  ·  load " + stats.load[0] : ""))
    lines.push("RAM  " + memPct + "%  ·  " + fmt1(stats.mem_used_gib) + " / " + fmt1(stats.mem_total_gib) + " GiB")
    if (tempC !== null) lines.push((stats.temp_label || "TEMP") + "  " + tempC + "°C")
    for (var i = 0; i < gpus.length; i++)
      lines.push((gpus[i].model || gpus[i].name) + "  " + Math.round(gpus[i].util) + "%"
                 + (gpus[i].temp !== null && gpus[i].temp !== undefined ? "  ·  " + Math.round(gpus[i].temp) + "°C" : ""))
    if (battery) lines.push("BAT  " + battery.pct + "%  " + battery.status)
    if (stats.uptime) lines.push("up " + stats.uptime)
    lines.push("")
    lines.push("Left click: details   ·   Right click: expand")
    return lines.join("\n")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: Math.round(button.implicitWidth * 0.5)

  // ---------------------------------------------------------------- helpers
  function fmt1(x) {
    var n = Number(x)
    if (!isFinite(n)) return "?"
    return (Math.round(n * 10) / 10).toFixed(1)
  }
  function fmtGhz(mhz) {
    var n = Number(mhz)
    if (!isFinite(n) || n <= 0) return ""
    return (Math.round(n / 100) / 10).toFixed(1) + " GHz"
  }
  function fmtSpeed(kbs) {
    var n = Number(kbs) || 0
    return n >= 1024 ? (Math.round(n / 102.4) / 10).toFixed(1) + " MB/s" : Math.round(n) + " KB/s"
  }
  function fmtSize(gb) {
    var n = Number(gb) || 0
    if (n >= 1000) return (Math.round(n / 100) / 10).toFixed(1).replace(/\.0$/, "") + " TB"
    return Math.round(n) + " GB"
  }
  function meterColor(v, warn, crit) {
    if (v >= crit) return Color.urgent
    if (v >= warn) return Qt.tint(Color.accent, Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.5))
    return Color.accent
  }

  function refresh() {
    // One sample at a time. The deadline on the runner below makes sure a
    // wedged backend (a hung nvidia-smi, an unresponsive sensor) releases the
    // slot instead of freezing the readout for the rest of the session.
    if (statsRun.running) return
    statsRun.start(root.opened
      ? [root.script, "stats", "--full"]
      : [root.script, "stats"])
  }

  function parseStats(text) {
    try {
      var data = JSON.parse(text)
      if (data && typeof data === "object") {
        root.lastSampleMs = Date.now()
        root.stalled = false
        root.stats = data
      }
    } catch (e) {
      // Transient parse failures (sensors warning on stderr etc.) - keep last good.
    }
  }

  // Persisting that choice is the shell's job, not this plugin's. The shell
  // writes the widget's own entry in shell.json on request - the same call
  // Omarchy's tray and clock use for their runtime state - and it will only
  // write the entry belonging to the plugin that asks.
  //
  // This plugin used to keep a file of its own under $XDG_STATE_HOME instead.
  // That meant validating a path that any process running as this user could
  // rearrange underneath it, which is a hard thing to get right and was the
  // subject of two rounds of security review. Remembering one boolean never
  // needed a file, and now there is not one to get wrong.
  function save(key, value) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry[key] = value
    // Applied here first so the readout changes on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.shellApi && typeof root.shellApi.updateEntryInline === "function")
      root.shellApi.updateEntryInline(root.moduleName, entry)
  }

  function setExpanded(v) {
    if (root.expanded === v) return
    root.save("expanded", !!v)
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Bar readout, same thing right-click and scroll do.
    function expand(): void { root.setExpanded(true) }
    function collapse(): void { root.setExpanded(false) }
    function toggleExpanded(): void { root.setExpanded(!root.expanded) }
  }

  Component.onCompleted: {
    lastSampleMs = Date.now()
    refresh()
  }

  onOpenedChanged: if (opened) refresh()

  Timer {
    interval: root.opened ? 1500 : 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.refresh()
      root.stalled = (Date.now() - root.lastSampleMs) > root.staleAfterMs
    }
  }

  // ------------------------------------------------------------------ backend
  // One backend invocation with a deadline, and an escalation that takes
  // nothing here on trust.
  //
  // Quickshell's Process.running means "there is a process object", not "the
  // program is still there": setting it false sends SIGTERM and the property
  // stays true until the child actually exits. Neither reading is a safe basis
  // for killing something, so the escalation is keyed on the pid the deadline
  // recorded and runs whatever this side believes - including after the child
  // has exited, because a child exiting says nothing about the helpers
  // underneath it, which can still be running and holding the pipe.
  //
  // What it does about that pid is hwmon.sh's decision, not this file's:
  // `reap` re-derives group, session, age and command line from /proc, refuses
  // anything that is not still one of ours, and does nothing at all when the
  // group is already empty.
  component Guarded: QtObject {
    id: g
    signal finished(string text)

    property int deadlineMs: 10000
    property int watchedPid: 0
    readonly property bool running: proc.running

    function start(argv) {
      if (proc.running) return false
      proc.command = root.launch(argv)
      proc.running = true
      watchdog.restart()
      return true
    }

    property Process proc: Process {
      // Only the deadline is cancelled here. The escalation stays armed on
      // purpose - see above.
      onExited: watchdog.stop()
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: g.finished(text)
      }
    }

    property Timer watchdog: Timer {
      interval: g.deadlineMs
      repeat: false
      onTriggered: {
        if (!g.proc.running) return
        g.watchedPid = Number(g.proc.processId) || 0
        g.proc.running = false          // SIGTERM, which is only a request
        if (g.watchedPid) escalation.restart()
      }
    }

    property Timer escalation: Timer {
      interval: 3000
      repeat: false
      onTriggered: {
        var pid = g.watchedPid
        g.watchedPid = 0
        if (pid) root.reap(pid, Math.ceil(g.deadlineMs / 1000))
      }
    }
  }

  // The deadline doubles as the minimum age the reaper will accept for that
  // pid: anything younger cannot be the process this one was waiting on, so a
  // recycled number is refused instead of killed.
  Guarded {
    id: statsRun
    deadlineMs: 10000
    onFinished: function (text) { root.parseStats(text) }
  }

  // Reaps are rare and run one at a time. A second request arriving while one
  // is in flight is queued rather than dropped: by definition it names a
  // process that did not go away on its own.
  property var reapQueue: []

  function reap(pid, minAgeSec) {
    if (reapProc.running) { root.reapQueue.push([pid, minAgeSec]); return }
    reapProc.command = root.launch([root.script, "reap", String(pid), String(minAgeSec)])
    reapProc.running = true
  }

  Process {
    id: reapProc
    onExited: {
      if (root.reapQueue.length === 0) return
      var next = root.reapQueue.shift()
      Qt.callLater(function () { root.reap(next[0], next[1]) })
    }
  }

  // ================================================================ bar button
  Item {
    id: button
    anchors.fill: parent

    implicitWidth: readout.implicitWidth + Style.space(17)
    implicitHeight: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal

    Row {
      id: readout
      anchors.centerIn: parent
      spacing: Style.space(9)

      BarMetric {
        glyph: "" // nf-oct-cpu
        value: root.degraded ? "--" : root.cpuPct + "%"
        hot: !root.degraded && root.cpuPct >= 90
      }
      BarMetric {
        visible: root.expanded
        glyph: "󰍛" // nf-md-memory
        value: root.degraded ? "--" : root.memPct + "%"
        hot: !root.degraded && root.memPct >= 90
      }
      BarMetric {
        visible: root.tempC !== null && !root.degraded
        glyph: "󰔏" // nf-md-thermometer
        value: (root.tempC === null ? "--" : root.tempC + "°")
        hot: root.tempC !== null && root.tempC >= 88
      }
      BarMetric {
        visible: root.expanded && !root.degraded && root.gpus.length > 0
        glyph: "󰢮" // nf-md-expansion_card_variant
        value: root.gpuPct + "%"
        hot: root.gpuPct >= 90
      }
      BarMetric {
        visible: root.expanded && !root.degraded && root.battery !== null
        glyph: "󰁹" // nf-md-battery
        value: (root.battery ? root.battery.pct + "%" : "")
        hot: root.battery !== null && root.battery.pct <= 15
                && String(root.battery.status).toLowerCase().indexOf("charg") < 0
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function (mouse) {
        if (mouse.button === Qt.LeftButton) root.toggle()
        else root.setExpanded(!root.expanded)
      }
      onWheel: function (wheel) {
        root.setExpanded(wheel.angleDelta.y < 0 ? true : (wheel.angleDelta.y > 0 ? false : root.expanded))
      }
      onEntered: if (root.bar) root.bar.showTooltip(button, root.tooltipText)
      onExited: if (root.bar) root.bar.hideTooltip(button)
    }
  }

  component BarMetric: Row {
    property string glyph: ""
    property string value: ""
    property bool hot: false
    spacing: Style.space(3)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

    Text {
      textFormat: Text.PlainText
      text: parent.glyph
      color: parent.hot ? Color.urgent : (root.bar ? root.bar.barForeground : Color.foreground)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
      opacity: 0.9
    }
    Text {
      textFormat: Text.PlainText
      text: parent.value
      color: parent.hot ? Color.urgent : (root.bar ? root.bar.barForeground : Color.foreground)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      font.bold: parent.hot
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // ================================================================ detail panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Hardware"
            meta: root.stats.uptime ? "up " + root.stats.uptime : "System Monitor"
            foreground: root.fg
            iconComponent: Component {
              Text {
                text: ""
                color: root.fg
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.display
              }
            }
          }

          // -------------------------------------------------- Backend trouble
          // Say what went wrong instead of leaving the panel full of zeroes.
          Item {
            width: parent.width
            visible: root.degraded
            implicitHeight: errCol.implicitHeight
            Column {
              id: errCol
              width: parent.width
              spacing: Style.space(4)
              InfoRow {
                label: "Status"
                value: root.statsError !== "" ? root.statsError
                     : "The last sample did not finish in time and was stopped."
              }
            }
          }

          // -------------------------------------------------- System
          Item {
            width: parent.width
            visible: !!(root.stats.cpu_model || (root.stats.host && root.stats.host.model))
            implicitHeight: sysCol.implicitHeight
            Column {
              id: sysCol
              width: parent.width
              spacing: Style.space(4)

              InfoRow {
                label: "Host"
                value: root.stats.host && root.stats.host.model ? root.stats.host.model : ""
              }
              InfoRow {
                label: "CPU"
                value: root.stats.cpu_model || ""
              }
              InfoRow {
                label: "Cores"
                value: {
                  var t = root.stats.cpu_topology
                  if (!t) return ""
                  var s = t.cores + (t.cores === 1 ? " core" : " cores")
                          + "  ·  " + t.threads + (t.threads === 1 ? " thread" : " threads")
                  if (t.sockets > 1) s += "  ·  " + t.sockets + " sockets"
                  return s
                }
              }
              InfoRow {
                label: "OS"
                value: {
                  if (!root.stats.host) return ""
                  var s = root.stats.host.distro || ""
                  if (root.stats.host.kernel) s += (s ? "  ·  " : "") + root.stats.host.kernel
                  if (root.stats.host.arch) s += (s ? "  ·  " : "") + root.stats.host.arch
                  return s
                }
              }
            }
          }

          // -------------------------------------------------- CPU
          PanelSeparator { width: parent.width; foreground: root.fg }

          SectionHead {
            title: "CPU"
            detail: root.cpuPct + "%   ·   " + root.fmtGhz(root.stats.freq_mhz)
                    + (root.stats.freq_max_mhz ? " / " + root.fmtGhz(root.stats.freq_max_mhz) : "")
                    + (root.stats.load ? "   ·   load " + root.stats.load.join(" ") : "")
          }
          Meter { width: parent.width; value: root.cpuPct }

          Item {
            width: parent.width
            visible: root.cpuCells.length > 0
            implicitHeight: cpuGrid.y + cpuGrid.implicitHeight

            Row {
              id: cpuViewToggle
              anchors.right: parent.right
              spacing: Style.space(3)
              Repeater {
                model: [{ key: "cores", label: "Cores" }, { key: "threads", label: "Threads" }]
                Rectangle {
                  id: seg
                  required property var modelData
                  readonly property bool current: root.cpuView === seg.modelData.key
                  width: segLabel.implicitWidth + Style.space(10)
                  height: Style.space(15)
                  radius: height / 2
                  color: seg.current ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.25)
                                     : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
                  Text {
                    id: segLabel
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: seg.modelData.label
                    color: root.fg
                    opacity: seg.current ? 1 : 0.55
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setCpuView(seg.modelData.key)
                  }
                }
              }
            }

            Grid {
              id: cpuGrid
              anchors.top: cpuViewToggle.bottom
              anchors.topMargin: Style.space(5)
              width: parent.width
              columns: 4
              columnSpacing: Style.space(4)
              rowSpacing: Style.space(4)
              Repeater {
                model: root.cpuCells
                CoreCell {
                  required property var modelData
                  label: modelData.label
                  pct: modelData.pct
                  cellW: (cpuGrid.width - Style.space(4) * 3) / 4
                }
              }
            }
          }

          // -------------------------------------------------- Memory
          PanelSeparator { width: parent.width; foreground: root.fg }

          SectionHead {
            title: "MEMORY"
            detail: root.fmt1(root.stats.mem_used_gib) + " / " + root.fmt1(root.stats.mem_total_gib) + " GiB"
          }
          Meter { width: parent.width; value: root.memPct }

          Item {
            width: parent.width
            visible: Number(root.stats.swap_total_gib) > 0
            implicitHeight: swapCol.implicitHeight
            Column {
              id: swapCol
              width: parent.width
              spacing: Style.space(4)
              SectionHead {
                title: "SWAP"
                detail: root.fmt1(root.stats.swap_used_gib) + " / " + root.fmt1(root.stats.swap_total_gib) + " GiB"
              }
              Meter { width: parent.width; value: Math.round(Number(root.stats.swap_pct) || 0) }
            }
          }

          // -------------------------------------------------- Thermals
          PanelSeparator { width: parent.width; foreground: root.fg }

          SectionHead { title: "THERMALS & FANS" }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Chip {
              visible: root.tempC !== null
              text: (root.stats.temp_label || "CPU") + "  " + (root.tempC === null ? "--" : root.tempC + "°C")
              warnColor: root.tempC !== null && root.tempC >= 85
            }
            Repeater {
              model: root.gpus
              Chip {
                required property var modelData
                visible: modelData.temp !== null && modelData.temp !== undefined
                text: (modelData.model || modelData.name) + "  " + Math.round(modelData.temp) + "°C"
                warnColor: Number(modelData.temp) >= 85
              }
            }
            Repeater {
              model: root.fans
              Chip {
                required property var modelData
                text: String(modelData.name).replace(/_/g, " ") + "  " + modelData.rpm + " rpm"
                      + (modelData.pwm !== null && modelData.pwm !== undefined
                         ? "  ·  " + Math.round(modelData.pwm) + "%" : "")
              }
            }
          }

          // -------------------------------------------------- GPU
          Item {
            width: parent.width
            visible: root.gpus.length > 0
            implicitHeight: gpuCol.implicitHeight
            Column {
              id: gpuCol
              width: parent.width
              spacing: Style.space(10)

              PanelSeparator { width: parent.width; foreground: root.fg }
              SectionHead { title: "GPU" }

              Repeater {
                model: root.gpus
                Column {
                  required property var modelData
                  width: gpuCol.width
                  spacing: Style.space(4)
                  SectionHead {
                    title: modelData.model || modelData.name
                    detail: (modelData.model ? modelData.name + "   ·   " : "")
                            + Math.round(Number(modelData.util) || 0) + "%"
                            + (modelData.mem_pct !== null && modelData.mem_pct !== undefined
                               ? "   ·   VRAM " + Math.round(modelData.mem_pct) + "%" : "")
                            + (modelData.temp !== null && modelData.temp !== undefined
                               ? "   ·   " + Math.round(modelData.temp) + "°C" : "")
                    small: true
                  }
                  Meter { width: parent.width; value: Math.round(Number(modelData.util) || 0) }
                }
              }
            }
          }

          // -------------------------------------------------- Storage devices
          Item {
            width: parent.width
            visible: (root.stats.storage || []).length > 0
            implicitHeight: stoCol.implicitHeight
            Column {
              id: stoCol
              width: parent.width
              spacing: Style.space(8)

              PanelSeparator { width: parent.width; foreground: root.fg }
              SectionHead { title: "STORAGE" }

              Repeater {
                model: root.stats.storage || []
                Item {
                  required property var modelData
                  width: stoCol.width
                  implicitHeight: stoRow.implicitHeight
                  Row {
                    id: stoRow
                    width: parent.width
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.model || modelData.name
                      width: parent.width * 0.58
                      elide: Text.ElideRight
                      color: root.fg
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: root.fmtSize(modelData.size_gb) + "  ·  " + (modelData.tran || modelData.kind)
                            + (modelData.temp !== null && modelData.temp !== undefined
                               ? "  ·  " + Math.round(modelData.temp) + "°C" : "")
                      width: parent.width * 0.42
                      horizontalAlignment: Text.AlignRight
                      color: Qt.darker(root.fg, 1.3)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.body
                    }
                  }
                }
              }
            }
          }

          // -------------------------------------------------- Disks
          Item {
            width: parent.width
            visible: root.disks.length > 0
            implicitHeight: diskCol.implicitHeight
            Column {
              id: diskCol
              width: parent.width
              spacing: Style.space(10)

              PanelSeparator { width: parent.width; foreground: root.fg }
              SectionHead { title: "DISKS" }

              Repeater {
                model: root.disks
                Column {
                  required property var modelData
                  width: diskCol.width
                  spacing: Style.space(4)
                  SectionHead {
                    title: modelData.mount
                    detail: (modelData.dev ? modelData.dev + "   ·   " : "")
                            + root.fmt1(modelData.used_gib) + " / " + root.fmt1(modelData.total_gib) + " GiB"
                    small: true
                  }
                  Meter { width: parent.width; value: Number(modelData.pct) || 0; warn: 85; crit: 95 }
                }
              }
            }
          }

          // -------------------------------------------------- Network
          Item {
            width: parent.width
            visible: root.netList.length > 0
            implicitHeight: netCol.implicitHeight
            Column {
              id: netCol
              width: parent.width
              spacing: Style.space(8)

              PanelSeparator { width: parent.width; foreground: root.fg }
              SectionHead { title: "NETWORK" }

              Repeater {
                model: root.netList
                Item {
                  required property var modelData
                  width: netCol.width
                  implicitHeight: netRow.implicitHeight
                  Row {
                    id: netRow
                    width: parent.width
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.iface
                      width: parent.width * 0.32
                      elide: Text.ElideRight
                      color: root.fg
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: "↓ " + root.fmtSpeed(modelData.rx_kbs) + "    ↑ " + root.fmtSpeed(modelData.tx_kbs)
                      width: parent.width * 0.68
                      horizontalAlignment: Text.AlignRight
                      color: Qt.darker(root.fg, 1.3)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.body
                    }
                  }
                }
              }
            }
          }

          // -------------------------------------------------- Top processes
          Item {
            width: parent.width
            visible: (root.stats.top_cpu || []).length > 0
            implicitHeight: procCol.implicitHeight
            Column {
              id: procCol
              width: parent.width
              spacing: Style.space(8)

              PanelSeparator { width: parent.width; foreground: root.fg }
              SectionHead { title: "TOP PROCESSES" }

              Row {
                width: parent.width
                spacing: Style.space(12)
                ProcList { title: "CPU"; model2: root.stats.top_cpu || []; colW: (procCol.width - Style.space(12)) / 2 }
                ProcList { title: "RAM"; model2: root.stats.top_mem || []; colW: (procCol.width - Style.space(12)) / 2 }
              }
            }
          }

          // -------------------------------------------------- Battery
          Item {
            width: parent.width
            visible: root.battery !== null
            implicitHeight: batCol.implicitHeight
            Column {
              id: batCol
              width: parent.width
              spacing: Style.space(4)
              PanelSeparator { width: parent.width; foreground: root.fg }
              SectionHead {
                title: "BATTERY"
                detail: root.battery ? root.battery.status : ""
              }
              Meter {
                width: parent.width
                value: root.battery ? root.battery.pct : 0
                invert: true
                warn: 30
                crit: 15
              }
            }
          }

          Item { width: parent.width; height: Style.space(4) }
        }
      }
    }
  }

  // ---------------------------------------------------------------- sub-components
  component SectionHead: Item {
    property string title: ""
    property string detail: ""
    property bool small: false
    width: parent ? parent.width : 0
    implicitHeight: Math.max(t.implicitHeight, d.implicitHeight)

    PanelSectionHeader {
      id: t
      text: parent.title
      foreground: root.fg
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      fontSize: parent.small ? Style.font.caption : Style.font.bodySmall
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      id: d
      textFormat: Text.PlainText
      text: parent.detail
      visible: text !== ""
      color: Qt.darker(root.fg, 1.35)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Label / value line for the static system-info block.
  component InfoRow: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    visible: value !== ""
    implicitHeight: Math.max(infoLabel.implicitHeight, infoValue.implicitHeight)

    Text {
      id: infoLabel
      textFormat: Text.PlainText
      text: parent.label
      width: parent.width * 0.22
      color: Qt.darker(root.fg, 1.35)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.left: parent.left
      anchors.top: parent.top
    }
    Text {
      id: infoValue
      textFormat: Text.PlainText
      text: parent.value
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignRight
      color: root.fg
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      anchors.left: infoLabel.right
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      anchors.top: parent.top
    }
  }

  component Meter: Rectangle {
    property real value: 0
    property real warn: 78
    property real crit: 92
    property bool invert: false   // battery: low is bad

    implicitHeight: Style.space(7)
    radius: height / 2
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.13)

    readonly property real clamped: Math.max(0, Math.min(100, value))
    readonly property bool danger: invert ? clamped <= crit : clamped >= crit
    readonly property bool caution: invert ? clamped <= warn : clamped >= warn

    Rectangle {
      height: parent.height
      radius: parent.radius
      width: Math.max(parent.clamped > 0 ? parent.height : 0, parent.width * parent.clamped / 100)
      color: parent.danger ? Color.urgent
           : parent.caution ? Qt.tint(Color.accent, Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.45))
           : Color.accent
      Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    }
  }

  // One block of the CPU grid: a horizontal fill with the core (or thread)
  // number on the left and its load on the right. It used to be a vertical bar
  // with no label at all - this is the same reading in well under half the
  // height, and there is finally room to say which core you are looking at.
  component CoreCell: Item {
    id: cell
    property string label: ""
    property real pct: 0
    property real cellW: 10
    readonly property real clamped: Math.max(0, Math.min(100, pct))
    width: cellW
    height: Style.space(17)
    implicitHeight: Style.space(17)

    Rectangle {
      id: cellTrack
      anchors.fill: parent
      radius: Style.space(3)
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.13)
      clip: true

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Math.max(cell.clamped > 0 ? 1 : 0, parent.width * cell.clamped / 100)
        radius: parent.radius
        opacity: 0.85
        color: root.meterColor(cell.clamped, 78, 92)
        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }
    }
    Text {
      anchors.left: cellTrack.left
      anchors.leftMargin: Style.space(5)
      anchors.verticalCenter: cellTrack.verticalCenter
      textFormat: Text.PlainText
      text: cell.label
      color: root.fg
      opacity: 0.7
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
    }
    Text {
      anchors.right: cellTrack.right
      anchors.rightMargin: Style.space(5)
      anchors.verticalCenter: cellTrack.verticalCenter
      textFormat: Text.PlainText
      text: Math.round(cell.pct) + "%"
      color: root.fg
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  component Chip: Rectangle {
    property string text: ""
    property bool warnColor: false
    implicitWidth: chipLabel.implicitWidth + Style.space(16)
    implicitHeight: chipLabel.implicitHeight + Style.space(8)
    radius: Style.space(4)
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
    border.width: 1
    border.color: warnColor ? Color.urgent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)

    Text {
      id: chipLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.text
      color: parent.warnColor ? Color.urgent : root.fg
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  component ProcList: Column {
    property string title: ""
    property var model2: []
    property real colW: 160
    width: colW
    spacing: Style.space(3)

    Text {
      textFormat: Text.PlainText
      text: parent.title
      color: Qt.darker(root.fg, 1.35)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Repeater {
      model: parent.model2
      Row {
        required property var modelData
        width: parent.width
        Text {
          textFormat: Text.PlainText
          text: modelData.name
          width: parent.width * 0.68
          elide: Text.ElideRight
          color: root.fg
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          textFormat: Text.PlainText
          text: root.fmt1(modelData.pct) + "%"
          width: parent.width * 0.32
          horizontalAlignment: Text.AlignRight
          color: Qt.darker(root.fg, 1.3)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
