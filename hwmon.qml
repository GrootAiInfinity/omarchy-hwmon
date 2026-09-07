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
  moduleName: "groot.hwmon"
  ipcTarget: "groot.hwmon"

  // Resolve the bundled backend script relative to this plugin's own folder,
  // wherever `omarchy plugin add` installed it.
  readonly property string pluginDir: {
    var dir = String(Qt.resolvedUrl("."))
    return dir.replace(/^file:\/\//, "").replace(/\/$/, "")
  }
  readonly property string script: pluginDir + "/hwmon.sh"
  readonly property string stateFile: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-hwmon.expanded"

  property var stats: ({})
  property bool expanded: setting("expanded", false)

  readonly property int cpuPct: Math.round(Number(stats.cpu_pct) || 0)
  readonly property int memPct: Math.round(Number(stats.mem_pct) || 0)
  readonly property var tempC: (stats.temp_c === null || stats.temp_c === undefined) ? null : Math.round(stats.temp_c)
  readonly property var gpus: stats.gpus || []
  readonly property var disks: stats.disks || []
  readonly property var netList: stats.net || []
  readonly property var fans: stats.fans || []
  readonly property var battery: stats.battery || null
  readonly property real gpuPct: gpus.length > 0 ? Math.round(Number(gpus[0].util) || 0) : 0

  // Hottest thing worth alarming about, for the bar glyph tint.
  readonly property bool alarm: cpuPct >= 90 || memPct >= 90 || (tempC !== null && tempC >= 88)

  readonly property color fg: Color.popups.text

  readonly property string tooltipText: {
    var lines = []
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
    if (statsProc.running) return
    statsProc.command = root.opened
      ? [root.script, "stats", "--full"]
      : [root.script, "stats"]
    statsProc.running = true
  }

  function parseStats(text) {
    try {
      var data = JSON.parse(text)
      if (data && typeof data === "object") root.stats = data
    } catch (e) {
      // Transient parse failures (sensors warning on stderr etc.) - keep last good.
    }
  }

  function setExpanded(v) {
    root.expanded = v
    writeStateProc.command = ["bash", "-c", "mkdir -p \"$(dirname '" + root.stateFile + "')\" && printf '%s' " + (v ? "1" : "0") + " > '" + root.stateFile + "'"]
    if (!writeStateProc.running) writeStateProc.running = true
  }

  Component.onCompleted: {
    loadStateProc.running = true
    refresh()
  }

  onOpenedChanged: if (opened) refresh()

  Timer {
    interval: root.opened ? 1500 : 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: statsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseStats(text)
    }
  }

  Process {
    id: loadStateProc
    command: ["bash", "-c", "cat '" + root.stateFile + "' 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text).trim()
        if (t === "0" || t === "1") root.expanded = (t === "1")
      }
    }
  }

  Process { id: writeStateProc }

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
        value: root.cpuPct + "%"
        hot: root.cpuPct >= 90
      }
      BarMetric {
        visible: root.expanded
        glyph: "󰍛" // nf-md-memory
        value: root.memPct + "%"
        hot: root.memPct >= 90
      }
      BarMetric {
        visible: root.tempC !== null
        glyph: "󰔏" // nf-md-thermometer
        value: (root.tempC === null ? "--" : root.tempC + "°")
        hot: root.tempC !== null && root.tempC >= 88
      }
      BarMetric {
        visible: root.expanded && root.gpus.length > 0
        glyph: "󰢮" // nf-md-expansion_card_variant
        value: root.gpuPct + "%"
        hot: root.gpuPct >= 90
      }
      BarMetric {
        visible: root.expanded && root.battery !== null
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

          Grid {
            width: parent.width
            visible: (root.stats.cpu_cores || []).length > 0
            columns: 8
            columnSpacing: Style.space(4)
            rowSpacing: Style.space(4)
            Repeater {
              model: root.stats.cpu_cores || []
              CoreBar {
                required property var modelData
                pct: Number(modelData) || 0
                cellW: (panelColumn.width - Style.space(4) * 7) / 8
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

  component CoreBar: Item {
    id: coreBar
    property real pct: 0
    property real cellW: 10
    readonly property real clamped: Math.max(0, Math.min(100, pct))
    width: cellW
    height: Style.space(40)
    implicitHeight: Style.space(40)

    Rectangle {
      id: coreTrack
      anchors.fill: parent
      radius: Style.space(2)
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.13)
    }
    Rectangle {
      anchors.left: coreTrack.left
      anchors.right: coreTrack.right
      anchors.bottom: coreTrack.bottom
      radius: Style.space(2)
      height: Math.max(coreBar.clamped > 0 ? 1 : 0, coreTrack.height * coreBar.clamped / 100)
      color: coreBar.clamped >= 92 ? Color.urgent
           : coreBar.clamped >= 78 ? Qt.tint(Color.accent, Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.45))
           : Color.accent
      Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
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
