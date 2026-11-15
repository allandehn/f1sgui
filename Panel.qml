import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import QtQuick.Effects

// Spoiler-free F1 weekend indicator + panel for the Omarchy bar. Data comes
// from OpenF1 through the bundled fetch.sh (same API, cache fallback and
// weekend choice as the f1schedule CLI). The bar shows a countdown to the
// next session, or LIVE while a session runs; the panel lists the weekend's
// timetable in local and circuit time. No results, standings, or driver data
// are ever shown.
Panel {
  id: root
  moduleName: "allandehn.f1"
  ipcTarget: "allandehn.f1"
  manageIpc: false

  // --- Data state (filled by fetch.sh) ---
  property var f1: null          // parsed fetch.sh JSON
  property bool fetching: false
  property string lastError: ""
  property string fetchNote: ""    // "cached" / "cached · live session lock" etc.
  property bool staleCache: false

  // --- Countdown state ---
  property date nowDate: new Date()

  readonly property var upcoming: f1 ? nextSession(f1) : null
  readonly property var ongoing: f1 ? currentSession(f1) : null
  readonly property bool finished: f1 ? allDone(f1) : false

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Accent highlight for the next / live row, same hue logic as pvpn.
  readonly property color selectedFill: bar ? Commons.Color.accent : "transparent"

  // Circuit timezone: OpenF1 gives a fixed offset per session (gmt_offset),
  // so circuit time is a fixed shift from UTC. We format the circuit-local
  // time in JS by shifting the UTC timestamp.
  function offsetSeconds(gmt) {
    if (!gmt) return 0
    var m = /^([+-])(\d{2}):(\d{2}):(\d{2})$/.exec(gmt)
    if (!m) return 0
    var secs = parseInt(m[2], 10) * 3600 + parseInt(m[3], 10) * 60 + parseInt(m[4], 10)
    return m[1] === "-" ? -secs : secs
  }

  // Format an epoch (seconds) in the circuit zone: shift by the offset and
  // format as UTC. Shows "Mon 02 Jan, 15:04" style, hour24 always for the
  // circuit column to keep it compact.
  function circuitTime(epoch, gmt) {
    var d = new Date((epoch + offsetSeconds(gmt)) * 1000)
    return fmtDay(d) + " " + pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes())
  }

  function localTime(epoch) {
    var d = new Date(epoch * 1000)
    var h24 = use24Hour()
    var h = d.getHours()
    var suffix = ""
    if (!h24) {
      suffix = h >= 12 ? " PM" : " AM"
      h = h % 12
      if (h === 0) h = 12
    }
    return fmtDay(d) + " " + pad(h) + ":" + pad(d.getMinutes()) + suffix
  }

  function fmtDay(d) {
    var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return days[d.getDay()] + " " + pad(d.getDate()) + " " + months[d.getMonth()]
  }

  function pad(n) { return (n < 10 ? "0" : "") + n }

  // 24h clock detection: Go's clock.go reads TZ / /etc/localtime and
  // zone.tab. QML can't; run the tiny probe once via a shell one-liner.
  property bool _24hLoaded: false
  property bool _24h: true
  Process {
    id: clockProbe
    command: ["sh", "-c", 'z=${TZ:-$(readlink -f /etc/localtime)}; z=${z##*/zoneinfo/}; c=$(awk -F"\\t" -v z="$z" \'$3==z {print $1; exit}\' /usr/share/zoneinfo/zone.tab 2>/dev/null); c=${c%%,*}; case $c in US|PH|MX|CO|HN|GT|SV|NI|PA|PR|IN|PK|EG|SA|AU|NZ|IE|CA) echo 12;; *) echo 24;; esac']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root._24h = text.trim() !== "12"
        root._24hLoaded = true
      }
    }
  }

  function use24Hour() { return _24h }

  function shortLabel(s) {
    var name = s.name || ""
    var type = s.type || ""
    var label = (name === "" || name === type) ? type : name + " (" + type + ")"
    if (label.indexOf("Practice 1") === 0) return "FP1"
    if (label.indexOf("Practice 2") === 0) return "FP2"
    if (label.indexOf("Practice 3") === 0) return "FP3"
    if (label.indexOf("Sprint Qualifying") !== -1) return "Sprint Quali"
    if (label === "Qualifying") return "Qualifying"
    if (label === "Sprint" || label.indexOf("Sprint (") === 0) return "Sprint"
    if (label === "Race" || label.indexOf("Race (") === 0) return "Race"
    return label
  }

  function sessionOf(data, fn) {
    var list = data.sessions || []
    for (var i = 0; i < list.length; i++) if (fn(list[i])) return list[i]
    return null
  }

  function nextSession(data) {
    var now = nowDate.getTime() / 1000
    return sessionOf(data, function(s) { return now < s.start })
  }

  function currentSession(data) {
    var now = nowDate.getTime() / 1000
    return sessionOf(data, function(s) { return now >= s.start && now < s.end })
  }

  function allDone(data) {
    var list = data.sessions || []
    if (list.length === 0) return false
    var now = nowDate.getTime() / 1000
    for (var i = 0; i < list.length; i++) if (now < list[i].end) return false
    return true
  }

  // Countdown like schedule.FormatCountdown: "2 days, 5 hours", "3 hours",
  // "45 minutes", "less than a minute".
  function countdown(epoch) {
    var until = epoch - nowDate.getTime() / 1000
    if (until < 60) return qsTr("less than a minute")
    var days = Math.floor(until / 86400)
    var hours = Math.floor((until % 86400) / 3600)
    var minutes = Math.floor((until % 3600) / 60)
    var parts = []
    if (days > 0) parts.push(days + (days === 1 ? qsTr(" day") : qsTr(" days")))
    if (hours > 0) parts.push(hours + (hours === 1 ? qsTr(" hour") : qsTr(" hours")))
    if (days === 0 && minutes > 0) parts.push(minutes + (minutes === 1 ? qsTr(" minute") : qsTr(" minutes")))
    return parts.join(", ")
  }

  function refresh() {
    if (fetching) return
    fetching = true
    fetchProc.running = true
  }

  // --- Data process: fetch.sh prints one JSON object ---
  Process {
    id: fetchProc
    command: [Qt.resolvedUrl("fetch.sh").toString().replace(/^file:\/\//, "")]
    property string out: ""
    property string err: ""
    property var exitCode: null
    property bool outDone: false
    property bool exited: false
    function settle() {
      if (!outDone || !exited) return
      root.fetching = false
      if (exitCode === 0 && out !== "") {
        try {
          root.f1 = JSON.parse(out)
          root.lastError = ""
          // cached flag and staleness, mirroring CacheSavedDuringWeekend
          if (root.f1.cached) {
            var saved = root.f1.saved_at ? new Date(root.f1.saved_at) : null
            var list = root.f1.sessions || []
            var note = qsTr("cached")
            if (saved && list.length > 0) {
              var first = list[0].start * 1000
              var last = list[list.length - 1].end * 1000
              var dayMs = 86400000
              var dayStart = new Date(first); dayStart.setHours(0, 0, 0, 0)
              var dayEnd = new Date(last); dayEnd.setHours(0, 0, 0, 0); dayEnd.setTime(dayEnd.getTime() + dayMs)
              var savedMs = saved.getTime()
              var inWindow = savedMs >= dayStart.getTime() && savedMs < dayEnd.getTime()
              if (!root.finished && !inWindow) {
                root.staleCache = true
                note = qsTr("cache is not from this race weekend")
              } else {
                note = qsTr("cached") + " · " + qsTr("saved") + " " + cacheTime(saved)
              }
            }
            root.fetchNote = note
          } else {
            root.staleCache = false
          }
        } catch (e) {
          root.lastError = qsTr("bad data from fetch") + ": " + e
        }
      } else if (err !== "") {
        root.lastError = err.trim()
      } else {
        root.lastError = qsTr("fetch failed (exit %1)").arg(exitCode)
      }
      root.refreshBar()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { fetchProc.out = text; fetchProc.outDone = true; fetchProc.settle() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { fetchProc.err = text }
    }
    onExited: function(code) { fetchProc.exitCode = code; fetchProc.exited = true; fetchProc.settle() }
  }

  function cacheTime(d) {
    var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return days[d.getDay()] + " " + d.getDate() + " " + months[d.getMonth()] + ", " +
      pad(d.getHours()) + ":" + pad(d.getMinutes())
  }

  // Tick: countdown to the minute while a session is upcoming; every second
  // is pointless. When live, tick every 30s to keep "LIVE: X" fresh.
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.nowDate = new Date()
  }
  // Align the minute countdown: a 60s timer started at an arbitrary offset
  // shows stale minutes for up to a minute. Tick at :00 of each minute.
  Timer {
    interval: 60000
    running: !root.ongoing && root.upcoming !== null
    repeat: true
    onTriggered: root.nowDate = new Date()
  }

  Timer {
    // Refresh data 4x/day: early, midday, afternoon, evening. Plus on open.
    interval: 6 * 3600 * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }
  Component.onCompleted: {
    refresh()
    clockProbe.running = true
  }

  onOpenedChanged: if (opened) {
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function status(): string {
      if (root.ongoing) return "live:" + shortLabel(root.ongoing)
      if (root.upcoming) return "in:" + countdown(root.upcoming.start)
      return root.finished ? "done" : "no-data"
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Bar icon: the checkered flag, monochrome, theme-following. No state
  // display — the tooltip and the panel carry the details.

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Icon-only: no label text.
    text: ""
    labelVisible: false
    hasVisualContent: true
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: {
      if (root.f1 === null) return "Motorsport"
      var t = (root.f1.meeting || "") + " · " + (root.f1.circuit || "")
      if (root.ongoing) t += " · " + qsTr("LIVE: ") + shortLabel(root.ongoing)
      else if (root.upcoming) t += " · " + qsTr("Next: ") + shortLabel(root.upcoming) + qsTr(" in ") + countdown(root.upcoming.start)
      else if (root.finished) t += " · " + qsTr("done")
      if (root.fetching) t += " · …"
      return t
    }
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }

    // The flag SVG paints in currentColor-like fashion via alpha mask:
    // Tray.qml's pattern — colorization keeps source lightness, so a black
    // fill would stay black.
    Item {
      id: iconHost
      property real size: Style.bar.iconSize
      width: size
      height: size
      anchors.centerIn: parent
      scale: button.pressScale

      Image {
        id: flagImage
        anchors.fill: parent
        source: Qt.resolvedUrl("flag.svg")
        sourceSize: Qt.size(iconHost.size * 2, iconHost.size * 2)
        mipmap: true
        visible: false
        layer.enabled: true
      }
      Rectangle {
        anchors.fill: parent
        color: root.foreground
        layer.enabled: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: flagImage
          maskThresholdMin: 0.5
          maskSpreadAtMin: 1.0
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(body.item ? body.item.implicitHeight : 0, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") { root.close(); root.refresh() }
      }

      // Panel contents only exist while it is open.
      Loader {
        id: body
        width: parent.width
        active: root.opened
        sourceComponent: Component {
          Column {
            width: body.width
            spacing: Style.space(12)

            Column {
              width: parent.width
              spacing: Style.space(6)

              PanelHero {
                width: parent.width
                title: root.f1 ? (root.f1.meeting || qsTr("No data")) : qsTr("No data")
                meta: {
                  if (root.f1 === null) return root.lastError !== "" ? root.lastError : qsTr("loading…")
                  var parts = [root.f1.circuit || "", root.f1.country || ""].filter(function(p) { return p !== "" })
                  return parts.join(" · ")
                }
                foreground: root.foreground
                fontFamily: root.fontFamily
                iconComponent: Component {
                  Item {
                    width: Math.round(Style.font.display)
                    height: Math.round(Style.font.display)
                    Image {
                      id: heroHelmet
                      anchors.fill: parent
                      source: Qt.resolvedUrl("helmet.png")
                      sourceSize: Qt.size(parent.width * 2, parent.height * 2)
                      mipmap: true
                      visible: false
                    }
                    // Recolor through alpha so the helmet follows the theme
                    // like every other icon (source fill is a fixed cream).
                    Rectangle {
                      anchors.fill: parent
                      color: root.foreground
                      layer.enabled: true
                      layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: heroHelmet
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                      }
                    }
                  }
                }
              }

              // Status line: LIVE / NEXT / done, colored like the TUI badges.
              Text {
                visible: root.f1 !== null && !root.finished
                width: parent.width
                textFormat: Text.PlainText
                text: {
                  if (root.ongoing) return qsTr("Live now: ") + shortLabel(root.ongoing)
                  if (root.upcoming) return qsTr("Next: ") + shortLabel(root.upcoming) + qsTr(" · in ") + countdown(root.upcoming.start)
                  return ""
                }
                color: root.ongoing ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                visible: root.finished
                width: parent.width
                textFormat: Text.PlainText
                text: qsTr("this race weekend has already finished")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                visible: root.fetchNote !== ""
                width: parent.width
                textFormat: Text.PlainText
                text: root.fetchNote
                color: root.staleCache ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                visible: root.lastError !== "" && root.f1 !== null
                width: parent.width
                textFormat: Text.PlainText
                text: root.lastError
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              foreground: root.foreground
              text: qsTr("Timetable")
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              // Column headers
              Row {
                width: parent.width
                spacing: 0
                Text {
                  width: parent.width * 0.34
                  textFormat: Text.PlainText
                  text: qsTr("Session")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  width: parent.width * 0.33
                  textFormat: Text.PlainText
                  text: qsTr("Local")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignRight
                }
                Text {
                  width: parent.width * 0.33
                  textFormat: Text.PlainText
                  text: qsTr("Circuit")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignRight
                }
              }

              Repeater {
                model: root.f1 ? (root.f1.sessions || []) : []

                delegate: Item {
                  id: row
                  required property var modelData
                  required property int index
                  width: parent.width
                  implicitHeight: sessionLabel.implicitHeight + Style.space(6)

                  readonly property bool isLive: {
                    var now = root.nowDate.getTime() / 1000
                    return now >= modelData.start && now < modelData.end
                  }
                  readonly property bool isNext: root.upcoming !== null && root.upcoming.start === modelData.start

                  Rectangle {
                    anchors.fill: parent
                    radius: Math.min(4, Style.space(4))
                    color: root.selectedFill
                    opacity: row.isLive ? 0.18 : (row.isNext ? 0.10 : 0)
                  }

                  Text {
                    id: sessionLabel
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.shortLabel(row.modelData)
                    color: row.isLive ? root.urgent : (row.isNext ? Commons.Color.accent : root.foreground)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: row.isLive || row.isNext
                  }

                  Text {
                    anchors.right: localAnchor.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.localTime(row.modelData.start)
                    color: row.isLive ? root.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    id: localAnchor
                    anchors.right: circuitCol.left
                    anchors.rightMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    text: ""
                  }

                  Text {
                    id: circuitCol
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.circuitTime(row.modelData.start, root.f1 ? root.f1.gmt_offset : null)
                    color: row.isLive ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
