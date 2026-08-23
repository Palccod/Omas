import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "PieModel.js" as PieModel

// Omas — a Fly-Pie-style radial menu for the Omarchy shell.
//
// The first wheel holds user-defined categories; pointing at one and
// clicking opens its sub-wheel (the tree grows as deep as the user's
// ~/.config/omarchy/extensions/omas.jsonc defines). Leaf nodes run their
// command through bash. This first version selects by pointing and
// clicking inside wedge sectors; gesture (marking) mode comes later.

Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property var rootWheel: null       // { title, items } built from the user config
  property var wheel: PieModel.demoWheel()
  property var navStack: []          // wheels we descended into, newest last
  property int hoveredIndex: -1
  property int wheelSerial: 0        // bumped on every wheel change; restarts animation + repaint
  property bool configReady: false
  property string configError: ""

  // Selection mode: "click" — hover a wedge, click to select (v0.1 behavior).
  // "stroke" — Fly-Pie marking mode: press and drag; pausing (dwell) or a
  // sharp turn selects the wedge you dragged through, chaining through
  // submenus without releasing. Drag into (or release over) the hub to go
  // back. The active mode comes from the summon payload's "mode" field or
  // falls back to the config's "selectionMode".
  property string selectionMode: "click"
  property string configSelectionMode: "click"
  property string payloadMode: ""

  // Summon payload {"edit": true} opens the wheel editor instead of the
  // pie. The editor edits a working copy and writes omas.jsonc on save.
  property bool editorOpen: false

  // ---- stroke (marking mode) state ------------------------------------
  property bool stroking: false
  property var trailPoints: []       // ink trail, wheelHolder coordinates
  property int trailSerial: 0
  property real strokeX: 0
  property real strokeY: 0
  property real sampleX: 0           // start of the current straight segment
  property real sampleY: 0
  property real lastDirX: 0          // direction of the previous segment
  property real lastDirY: 0
  property bool haveLastDir: false
  property real strokeDistSinceEvent: 0
  property int lastStrokeWedge: -1

  readonly property var items: wheel ? wheel.items : []
  readonly property int itemCount: items.length
  readonly property bool canGoBack: navStack.length > 0

  function ping() {
    return JSON.stringify({
      mode: selectionMode,
      payloadMode: payloadMode,
      configMode: configSelectionMode,
      editorOpen: editorOpen,
      formDepth: editor.formStack.length,
      opened: opened,
      stroking: stroking,
      items: itemCount,
      title: wheel ? wheel.title : ""
    })
  }

  // ---- ring geometry (logical px, before pieScale) ----------------------
  readonly property int hubRadius: Style.space(50)
  readonly property int itemSize: Style.space(64)
  readonly property int itemCenterRadius: hubRadius + Style.space(30) + itemSize / 2
  readonly property int wedgeInner: hubRadius + Style.space(14)
  readonly property int wedgeOuter: itemCenterRadius + itemSize / 2 + Style.space(22)
  readonly property real pieScale: {
    var available = Math.min(panel.width, panel.height) / 2 - Style.gapsOut * 3
    return available > 0 ? Math.min(1, available / wedgeOuter) : 1
  }

  function open(payloadJson) {
    if (!configReady) configFile.reload()
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    var mode = String(payload.selectionMode || payload.mode || "").toLowerCase()
    payloadMode = (mode === "stroke" || mode === "click") ? mode : ""
    selectionMode = payloadMode !== "" ? payloadMode : configSelectionMode
    navStack = []
    wheel = rootWheel || PieModel.demoWheel()
    opened = true
    clearStroke()
    if (payload.edit === true) {
      enterEditor()
      return
    }
    bumpWheel()
  }

  // The editor can be entered two ways: the summon payload ({"edit":true})
  // or clicking the hub on the root wheel.
  function enterEditor() {
    editorOpen = true
    var tree = rootWheel ? rootWheel.items : PieModel.demoWheel().items
    editor.beginEdit(JSON.parse(JSON.stringify(tree)), selectionMode)
  }

  function close() {
    opened = false
    editorOpen = false
    navStack = []
    wheel = rootWheel || PieModel.demoWheel()
    hoveredIndex = -1
    clearStroke()
  }

  // The editor's Save: write the config file and apply it immediately
  // (the file watcher will also reload it, harmlessly).
  function saveFromEditor(json) {
    writeProc.command = ["bash", "-c",
      "printf '%s' " + Util.shellQuote(json) + " > " + Util.shellQuote(configFile.path)]
    writeProc.running = true
    editorOpen = false
    applyConfig(json)
    navStack = []
    wheel = rootWheel || PieModel.demoWheel()
    bumpWheel()
  }

  Process {
    id: writeProc
    command: ["true"]
  }

  function bumpWheel() {
    hoveredIndex = -1
    wheelSerial++
    flyIn.restart()
  }

  function openItem(index) {
    var item = items[index]
    if (!item) return
    if (item.children.length > 0) {
      navStack = navStack.concat([wheel])
      wheel = { title: item.name, items: item.children }
      bumpWheel()
    } else if (item.command) {
      Util.execDetached(item.command)
      close()
    } else {
      console.warn("Omas: item '" + item.name + "' has no command and no children")
    }
  }

  function goBack() {
    if (navStack.length === 0) {
      close()
      return
    }
    var stack = navStack
    wheel = stack[stack.length - 1]
    navStack = stack.slice(0, -1)
    bumpWheel()
  }

  // ---- stroke engine (marking mode) ------------------------------------

  function distFromCenter(x, y) {
    var dx = x - wheelHolder.width / 2
    var dy = y - wheelHolder.height / 2
    return Math.sqrt(dx * dx + dy * dy)
  }

  function turnAngleDeg(x1, y1, x2, y2) {
    var dot = x1 * x2 + y1 * y2
    var m1 = Math.sqrt(x1 * x1 + y1 * y1)
    var m2 = Math.sqrt(x2 * x2 + y2 * y2)
    if (m1 === 0 || m2 === 0) return 0
    var cos = dot / (m1 * m2)
    cos = Math.max(-1, Math.min(1, cos))
    return Math.acos(cos) * 180 / Math.PI
  }

  function clearStroke() {
    stroking = false
    haveLastDir = false
    strokeDistSinceEvent = 0
    lastStrokeWedge = -1
    trailPoints = []
    trailSerial++
    dwellTimer.stop()
  }

  function beginStroke(x, y) {
    stroking = true
    strokeX = x
    strokeY = y
    sampleX = x
    sampleY = y
    haveLastDir = false
    strokeDistSinceEvent = 0
    lastStrokeWedge = hoveredIndex
    trailPoints = [{ x: x, y: y }]
    trailSerial++
    dwellTimer.restart()
  }

  // Forget recent motion so a fresh selection needs new intent — called
  // after every select/go-back so one gesture never triggers twice.
  function resetStrokeMotion() {
    sampleX = strokeX
    sampleY = strokeY
    haveLastDir = false
    strokeDistSinceEvent = 0
    lastStrokeWedge = -1
    dwellTimer.restart()
  }

  function updateStroke(x, y) {
    var dx = x - strokeX
    var dy = y - strokeY
    var moved = Math.sqrt(dx * dx + dy * dy)
    if (moved < 2) return
    strokeX = x
    strokeY = y
    strokeDistSinceEvent += moved
    var last = trailPoints.length > 0 ? trailPoints[trailPoints.length - 1] : null
    if (!last || Math.abs(x - last.x) + Math.abs(y - last.y) >= 4) {
      trailPoints.push({ x: x, y: y })
      if (trailPoints.length > 220) trailPoints.shift()
      trailSerial++
    }
    dwellTimer.restart()

    // Sample straight segments: once we've traveled far enough from the
    // segment start, compare directions. A sharp turn after enough travel
    // means "the wedge I just dragged through" — select it.
    var sdx = x - sampleX
    var sdy = y - sampleY
    var sdist = Math.sqrt(sdx * sdx + sdy * sdy)
    if (sdist >= 8) {
      if (haveLastDir && strokeDistSinceEvent > 24
          && turnAngleDeg(lastDirX, lastDirY, sdx, sdy) > 45) {
        var target = hoveredIndex >= 0 ? hoveredIndex : lastStrokeWedge
        resetStrokeMotion()
        if (target >= 0) openItem(target)
        return
      }
      lastDirX = sdx
      lastDirY = sdy
      haveLastDir = true
      sampleX = x
      sampleY = y
    }
  }

  function endStroke(x, y) {
    if (!stroking) return
    stroking = false
    dwellTimer.stop()
    if (hoveredIndex >= 0) {
      openItem(hoveredIndex)
    } else if (distFromCenter(x, y) < hubRadius) {
      goBack()
    } else {
      close()
    }
  }

  Timer {
    id: dwellTimer
    interval: 400
    onTriggered: {
      if (!root.stroking || !root.opened) return
      if (root.hoveredIndex >= 0) {
        root.resetStrokeMotion()
        root.openItem(root.hoveredIndex)
      } else if (root.distFromCenter(root.strokeX, root.strokeY) < root.hubRadius) {
        root.resetStrokeMotion()
        root.goBack()
      }
    }
  }

  // Map a point in wheel coordinates to a wedge index, or -1 when the
  // pointer is inside the hub or outside the ring.
  function wedgeIndexAt(x, y) {
    if (itemCount === 0) return -1
    var dx = x - wheelHolder.width / 2
    var dy = y - wheelHolder.height / 2
    var r = Math.sqrt(dx * dx + dy * dy)
    if (r < wedgeInner || r > wedgeOuter + itemSize / 2) return -1
    var deg = Math.atan2(dy, dx) * 180 / Math.PI
    if (deg < 0) deg += 360
    return Math.round((deg + 90) / (360 / itemCount)) % itemCount
  }

  function itemAngleRad(index) {
    return -Math.PI / 2 + index * 2 * Math.PI / itemCount
  }

  function applyConfig(raw) {
    var parsed = PieModel.parseConfig(raw)
    configError = parsed.error
    configSelectionMode = parsed.selectionMode !== "" ? parsed.selectionMode : "click"
    if (opened && payloadMode === "") selectionMode = configSelectionMode
    if (parsed.error) {
      console.warn("Omas: config error:", parsed.error)
      if (!rootWheel) rootWheel = PieModel.demoWheel()
    } else {
      rootWheel = { title: "Omas", items: parsed.items }
    }
    // Refresh a wheel that is on screen only when we're still at the root
    // and the editor isn't holding a working copy, so mid-navigation state
    // isn't yanked out from under the user.
    if (opened && !editorOpen && navStack.length === 0) {
      wheel = rootWheel
      bumpWheel()
    }
  }

  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy/extensions/omas.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: {
      configReady = true
      root.applyConfig(text())
    }
    onLoadFailed: {
      // No user config yet — the demo wheel doubles as the hint.
      configReady = true
      configError = ""
      rootWheel = PieModel.demoWheel()
      if (root.opened && root.navStack.length === 0) {
        root.wheel = rootWheel
        root.bumpWheel()
      }
    }
    onFileChanged: reload()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omas"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
      MouseArea {
        anchors.fill: parent
        // Clicking away exits the editor back to the wheel first; only a
        // second click on the scrim dismisses the menu.
        onClicked: if (root.editorOpen) root.editorOpen = false; else root.close()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onEscapePressed: function(event) {
        if (root.editorOpen) {
          // Steps back one editor level (dialog → form → browse); leaving
          // the editor returns to the wheel — the menu stays open.
          editor.handleKey(event)
        } else {
          root.clearStroke()
          root.goBack()
        }
        event.accepted = true
      }
    }

    Editor {
      id: editor
      anchors.fill: parent
      visible: root.editorOpen
      onEditorSaved: function(json) { root.saveFromEditor(json) }
      onEditorCanceled: root.editorOpen = false
    }

    Item {
      id: pieHost
      visible: !root.editorOpen
      anchors.centerIn: parent
      width: root.wedgeOuter * 2
      height: width
      scale: root.pieScale

      Item {
        id: wheelHolder
        anchors.fill: parent
        opacity: 0
        scale: 0.86

        ParallelAnimation {
          id: flyIn
          NumberAnimation {
            target: wheelHolder
            property: "opacity"
            from: 0; to: 1
            duration: 140
            easing.type: Easing.OutCubic
          }
          NumberAnimation {
            target: wheelHolder
            property: "scale"
            from: 0.86; to: 1
            duration: 170
            easing.type: Easing.OutCubic
          }
        }

        Canvas {
          id: wedges
          anchors.fill: parent
          // Any geometry/state the painting depends on funnels through this
          // counter; changing it requests a repaint.
          property int paintSerial: root.wheelSerial * 100000
            + (root.hoveredIndex + 2) * 1000 + root.itemCount
          onPaintSerialChanged: requestPaint()
          onVisibleChanged: if (visible) requestPaint()

          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var n = root.itemCount
            if (n === 0) return
            var cx = width / 2
            var cy = height / 2
            var step = 2 * Math.PI / n

            for (var i = 0; i < n; i++) {
              var mid = root.itemAngleRad(i)
              var hovered = i === root.hoveredIndex
              ctx.beginPath()
              ctx.arc(cx, cy, root.wedgeOuter, mid - step / 2, mid + step / 2, false)
              ctx.arc(cx, cy, root.wedgeInner, mid + step / 2, mid - step / 2, true)
              ctx.closePath()
              ctx.globalAlpha = hovered ? 0.22 : 0.05
              ctx.fillStyle = hovered ? Color.accent : Color.foreground
              ctx.fill()
            }

            // Connector from the hub edge to the hovered item's icon circle.
            if (root.hoveredIndex >= 0) {
              var a = root.itemAngleRad(root.hoveredIndex)
              ctx.globalAlpha = 0.6
              ctx.strokeStyle = Color.accent
              ctx.lineWidth = 2
              ctx.beginPath()
              ctx.moveTo(cx + Math.cos(a) * (root.hubRadius + 4), cy + Math.sin(a) * (root.hubRadius + 4))
              ctx.lineTo(cx + Math.cos(a) * (root.itemCenterRadius - root.itemSize / 2 - 4),
                         cy + Math.sin(a) * (root.itemCenterRadius - root.itemSize / 2 - 4))
              ctx.stroke()
            }
            ctx.globalAlpha = 1
          }
        }

        MouseArea {
          id: ringHit
          anchors.fill: parent
          hoverEnabled: true
          onPressed: function(mouse) {
            if (root.selectionMode === "stroke") root.beginStroke(mouse.x, mouse.y)
          }
          onPositionChanged: function(mouse) {
            root.hoveredIndex = root.wedgeIndexAt(mouse.x, mouse.y)
            if (root.stroking) root.updateStroke(mouse.x, mouse.y)
          }
          onReleased: function(mouse) {
            if (root.selectionMode === "stroke") root.endStroke(mouse.x, mouse.y)
          }
          onExited: root.hoveredIndex = -1
          onClicked: if (root.selectionMode === "click" && root.hoveredIndex >= 0)
            root.openItem(root.hoveredIndex)
        }

        // The ink trail of the current stroke. Kept in wheelHolder
        // coordinates, which stay stable across wheel changes, so a single
        // stroke chains visually through submenus until the menu closes.
        Canvas {
          id: trailCanvas
          anchors.fill: parent
          visible: root.selectionMode === "stroke"
          property int paintSerial: root.trailSerial
          onPaintSerialChanged: requestPaint()
          onVisibleChanged: if (visible) requestPaint()

          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            if (root.trailPoints.length < 2) return
            ctx.lineJoin = "round"
            ctx.lineCap = "round"
            ctx.strokeStyle = Color.accent
            for (var pass = 0; pass < 2; pass++) {
              ctx.globalAlpha = pass === 0 ? 0.22 : 0.75
              ctx.lineWidth = pass === 0 ? 12 : 4
              ctx.beginPath()
              ctx.moveTo(root.trailPoints[0].x, root.trailPoints[0].y)
              for (var i = 1; i < root.trailPoints.length; i++)
                ctx.lineTo(root.trailPoints[i].x, root.trailPoints[i].y)
              ctx.stroke()
            }
            ctx.globalAlpha = 1
          }
        }

        Repeater {
          model: root.items

          delegate: Item {
            id: slice
            required property int index
            required property var modelData

            x: wheelHolder.width / 2 + Math.cos(root.itemAngleRad(slice.index)) * root.itemCenterRadius - root.itemSize / 2
            y: wheelHolder.height / 2 + Math.sin(root.itemAngleRad(slice.index)) * root.itemCenterRadius - root.itemSize / 2
            width: root.itemSize
            height: root.itemSize

            readonly property bool hovered: slice.index === root.hoveredIndex

            Rectangle {
              id: circle
              anchors.top: parent.top
              anchors.horizontalCenter: parent.horizontalCenter
              width: root.itemSize
              height: root.itemSize
              radius: width / 2
              color: slice.hovered ? Style.selectedAccentFill : Color.menu.background
              border.color: slice.hovered ? Color.accent : Color.menu.border
              border.width: slice.hovered ? 2 : 1
              scale: slice.hovered ? 1.08 : 1
              Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

              Text {
                visible: slice.modelData.icon.charAt(0) !== "/"
                anchors.centerIn: parent
                text: slice.modelData.icon
                color: Color.menu.text
                font.pixelSize: Math.round(root.itemSize * 0.45)
              }

              Image {
                visible: slice.modelData.icon.charAt(0) === "/"
                anchors.centerIn: parent
                width: root.itemSize * 0.55
                height: width
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: slice.modelData.icon.charAt(0) === "/" ? slice.modelData.icon : ""
                asynchronous: true
              }
            }

            Text {
              anchors.top: circle.bottom
              anchors.topMargin: Style.spacing.xs
              anchors.horizontalCenter: parent.horizontalCenter
              width: root.itemSize + Style.space(60)
              horizontalAlignment: Text.AlignHCenter
              text: slice.modelData.name
              color: slice.hovered ? Color.accent : Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideMiddle
            }
          }
        }

        Rectangle {
          id: hub
          anchors.centerIn: parent
          width: root.hubRadius * 2
          height: width
          radius: width / 2
          color: Color.menu.background
          border.color: hubMouse.containsMouse ? Color.accent : Color.menu.border
          border.width: hubMouse.containsMouse ? 2 : 1

          MouseArea {
            id: hubMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            // In stroke mode the ring must own the press so a drag that
            // crosses the hub keeps its grab (hub drag = go back).
            onPressed: function(mouse) {
              if (root.selectionMode === "stroke") mouse.accepted = false
            }
            onPositionChanged: root.hoveredIndex = -1
            // Deeper wheels: back. Root wheel in click mode: the hub is
            // the door to the settings/editor panel.
            onClicked: {
              if (root.canGoBack || root.selectionMode !== "click") root.goBack()
              else root.enterEditor()
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.spacing.xxs

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: root.hoveredIndex >= 0
                  && root.items[root.hoveredIndex].icon.charAt(0) !== "/"
              text: root.hoveredIndex >= 0 ? root.items[root.hoveredIndex].icon : ""
              font.pixelSize: Style.font.display
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              width: root.hubRadius * 2 - Style.spacing.md
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              maximumLineCount: 2
              elide: Text.ElideRight
              text: root.configError !== "" ? "Config error"
                : (root.hoveredIndex >= 0 ? root.items[root.hoveredIndex].name
                  : (root.wheel ? root.wheel.title : "Omas"))
              color: root.hoveredIndex >= 0 ? Color.accent : Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.subtitle
              font.weight: root.hoveredIndex >= 0 ? Font.DemiBold : Font.Normal
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.selectionMode === "stroke"
                ? (root.canGoBack ? "drag to center = back" : "drag to select")
                : (root.canGoBack ? "back" : "settings")
              color: Util.alpha(Color.menu.text, 0.5)
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
