import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "PieModel.js" as PieModel

// Omas — a radial menu for the Omarchy shell.
//
// The first wheel holds user-defined categories; pointing at one and
// clicking opens its sub-wheel (the tree grows as deep as the user's
// ~/.config/omarchy/extensions/omas.jsonc defines). Leaf nodes run their
// command detached. Selection is by pointing and clicking inside wedge
// sectors; the hub goes back one level and, on the root wheel, opens
// the built-in editor. The wheel is summoned under the cursor (falling
// back to the panel center when the position can't be read).

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

  // Summon mode from the config: "click" (default) toggles with a single
  // key press; "hold" opens on press and launches whatever wedge is under
  // the pointer when the keys are released (see pick()).
  property string wheelMode: "click"

  // Summon payload {"edit": true} opens the wheel editor instead of the
  // pie. The editor edits a working copy and writes omas.jsonc on save.
  property bool editorOpen: false

  // Cursor point in panel coordinates (unclamped); x < 0 means no usable
  // cursor position was found at summon time.
  property point cursorAt: Qt.point(-1, -1)

  // Pointer position at the last hold-gesture anchor (summon or previous
  // pick). pick() only acts when the pointer has moved away from it, so a
  // press-release without a flick leaves the wheel up instead of
  // dismissing it on the spot.
  property point pickOrigin: Qt.point(-1, -1)

  // Wheel center: the cursor point clamped so the whole wheel stays on
  // screen, or the sentinel for "panel center". A binding on purpose —
  // the summon resolves the cursor before the panel has mapped, so the
  // clamp must follow the panel's real size once the window realizes it.
  readonly property point openAt: {
    if (cursorAt.x < 0) return Qt.point(-1, -1)
    var pad = wedgeOuter * pieScale + Style.gapsOut
    return Qt.point(
      Math.max(pad, Math.min(panel.width - pad, cursorAt.x)),
      Math.max(pad, Math.min(panel.height - pad, cursorAt.y)))
  }
  property bool openPending: false

  readonly property var items: wheel ? wheel.items : []
  readonly property int itemCount: items.length
  readonly property bool canGoBack: navStack.length > 0

  function ping() {
    return JSON.stringify({
      editorOpen: editorOpen,
      formDepth: editor.formStack.length,
      summonMode: editor.summonMode,
      opened: opened,
      mode: wheelMode,
      hovered: hoveredIndex,
      openAt: openAt.x + "," + openAt.y,
      openPending: openPending,
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
    if (!configReady) loadConfig()
    if (openPending) return
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (opened) {
      // Hold mode: a fresh press while the wheel is up must keep the
      // current level — chained hold-release gestures descend through
      // sub-wheels. Click mode keeps the old behavior (restart at root).
      if (wheelMode === "hold" && payload.edit !== true) {
        clickUsed = false   // new gesture: clicks from the last one no longer count
        return
      }
    }
    navStack = []
    wheel = rootWheel || PieModel.demoWheel()
    cursorAt = Qt.point(-1, -1)
    if (payload.edit === true) {
      opened = true
      enterEditor()
      return
    }
    // The wheel is placed under the cursor, so wait for the compositor to
    // report the pointer position (or a timeout, whichever comes first)
    // before showing anything — the panel must not flash up centered first.
    openPending = true
    cursorFallback.restart()
    cursorProc.running = true
  }

  // Release-to-launch for hold-mode keybinds: press summons, and the
  // release binding calls this via the shell IPC. Registering the release
  // binding is the explicit opt-in, so this works in both summon modes —
  // a click-mode user who adds it still gets the gesture (mode only
  // changes what pressing again does while the wheel is up). A fresh
  // cursor read (not the hover state — hover can lag or be absent
  // entirely) is mapped through the same wedge math the mouse uses; the
  // hub, the scrim, or a read failure all count as "dismiss".
  property real lastPickMs: 0

  // Set when a click selects on the wheel while a hold gesture is in
  // flight: the click owns the gesture, so the pending side-button
  // release must not fire another pick on top of it.
  property bool clickUsed: false

  function pick() {
    // Debounce: a chattering button or racing release events must not
    // resolve two picks from one gesture.
    var now = Date.now()
    if (now - lastPickMs < 150) return
    lastPickMs = now
    if (!opened || editorOpen || openPending || clickUsed) return
    pickProc.running = true
  }

  // Second half of pick(): map the global pointer position into wheel
  // coordinates (undoing the pie scale around its center) and select.
  // Classic radial-menu resolution: any flicked release picks the item
  // in that direction — a short flick that never leaves the hub ring
  // still resolves by angle, so the first release after summoning always
  // lands on something. A release without movement counts as a center
  // release (back one level, editor at the root); off the wheel
  // dismisses.
  function finishPick(raw) {
    var index = -1
    var moved = false
    var center = false
    var onWheel = false
    try {
      var t = String(raw || "").trim()
      var comma = t.indexOf(",")
      if (comma > 0) {
        var gx = parseFloat(t.substring(0, comma))
        var gy = parseFloat(t.substring(comma + 1))
        var p = localCursorCenter(gx, gy)
        if (p) {
          moved = Math.abs(p.x - pickOrigin.x) + Math.abs(p.y - pickOrigin.y) > Style.space(12)
          pickOrigin = p
          if (moved) {
            var csx = openAt.x >= 0 ? openAt.x : panel.width / 2
            var csy = openAt.y >= 0 ? openAt.y : panel.height / 2
            var lx = wheelHolder.width / 2 + (p.x - csx) / pieScale
            var ly = wheelHolder.height / 2 + (p.y - csy) / pieScale
            index = wedgeIndexAt(lx, ly)
            if (index < 0 && itemCount > 0) {
              var dx = lx - wheelHolder.width / 2
              var dy = ly - wheelHolder.height / 2
              if (Math.sqrt(dx * dx + dy * dy) < wedgeInner) {
                // Flick too short to reach the ring: pick by direction.
                var deg = Math.atan2(dy, dx) * 180 / Math.PI
                if (deg < 0) deg += 360
                index = Math.round((deg + 90) / (360 / itemCount)) % itemCount
              } else {
                onWheel = Math.abs(dx) < wheelHolder.width / 2
                  && Math.abs(dy) < wheelHolder.height / 2
              }
            }
          } else {
            center = true
          }
        }
      }
    } catch (e) {
      console.warn("Omas: pick failed:", e)
    }
    if (index >= 0) openItem(index)
    else if (center) { if (canGoBack) goBack(); else enterEditor() }
    else if (onWheel) return
    else if (moved) close()
  }

  // Second half of open(), called by the cursor read or its fallback timer.
  function finishOpen() {
    if (!openPending) return
    openPending = false
    cursorFallback.stop()
    opened = true
    clickUsed = false
    pickOrigin = cursorAt.x >= 0 ? Qt.point(cursorAt.x, cursorAt.y)
                                 : Qt.point(panel.width / 2, panel.height / 2)
    bumpWheel()
  }

  // Global (layout-space) cursor position → unclamped point in panel
  // coordinates, or null when it can't be resolved. The panel is a layer
  // surface without an explicit screen, so it maps to the compositor's
  // focused output — the same monitor the coordinates are converted
  // against. Null (cursor on another monitor, no IPC) opens centered.
  function localCursorCenter(gx, gy) {
    var mon = Hyprland.focusedMonitor
    if (!mon) return null
    if (gx < mon.x || gx >= mon.x + mon.width || gy < mon.y || gy >= mon.y + mon.height)
      return null
    return Qt.point(gx - mon.x, gy - mon.y)
  }

  // The editor can be entered two ways: the summon payload ({"edit":true})
  // or clicking the hub on the root wheel.
  function enterEditor() {
    editorOpen = true
    var tree = rootWheel ? rootWheel.items : PieModel.demoWheel().items
    editor.beginEdit(JSON.parse(JSON.stringify(tree)), wheelMode)
  }

  function close() {
    openPending = false
    cursorFallback.stop()
    opened = false
    editorOpen = false
    clickUsed = false
    navStack = []
    wheel = rootWheel || PieModel.demoWheel()
    hoveredIndex = -1
    cursorAt = Qt.point(-1, -1)
  }

  // The editor's Save: write the config file through FileView (bounded,
  // atomic temp-file + rename — no shell command is built) and apply it
  // immediately. The file watcher will also reload it, harmlessly. The
  // editor serializes only the item tree, so the summon mode chosen in
  // the editor is re-injected here — otherwise every editor save would
  // silently drop it.
  function saveFromEditor(json) {
    if (!json || json.length > PieModel.MAX_FILE_CHARS) {
      configError = "wheel exceeds size limits; nothing was written"
      return
    }
    var doc = json
    try {
      var mode = editor.summonMode === "hold" ? "hold" : "click"
      var obj = JSON.parse(json)
      if (!Array.isArray(obj) && obj.mode !== mode) {
        if (mode !== "click") obj.mode = mode
        else delete obj.mode
        doc = JSON.stringify(obj, null, 2) + "\n"
        if (doc.length > PieModel.MAX_FILE_CHARS) {
          configError = "wheel exceeds size limits; nothing was written"
          return
        }
      }
    } catch (e) { doc = json }
    configFile.setText(doc)
    editorOpen = false
    applyConfig(doc)
    navStack = []
    wheel = rootWheel || PieModel.demoWheel()
    bumpWheel()
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

  // Config rejection at any boundary (read or parse): keep the last good
  // wheel on screen and say why.
  function rejectConfig(msg) {
    configError = msg
    console.warn("Omas: config error:", msg)
    if (!rootWheel) rootWheel = PieModel.demoWheel()
    if (opened && !editorOpen && navStack.length === 0) {
      wheel = rootWheel
      bumpWheel()
    }
  }

  // Raw text funnels through here; PieModel.parseConfig enforces the
  // document budgets before anything is materialized.
  function applyConfig(raw) {
    var parsed = PieModel.parseConfig(raw)
    configError = parsed.error
    if (parsed.error) {
      rejectConfig(parsed.error)
    } else {
      rootWheel = { title: "Omas", items: parsed.items }
      wheelMode = parsed.mode === "hold" ? "hold" : "click"
      // Refresh a wheel that is on screen only when we're still at the root
      // and the editor isn't holding a working copy, so mid-navigation
      // state isn't yanked out from under the user.
      if (opened && !editorOpen && navStack.length === 0) {
        wheel = rootWheel
        bumpWheel()
      }
    }
  }

  // ---- bounded config reader --------------------------------------------
  // The config file is user-replaceable, so it is never loaded through the
  // preloading FileView (which would materialize the whole document inside
  // QML before any check could run). Instead a producer helper opens it
  // with O_NOFOLLOW, fstats the descriptor, and reads at most MAX_FILE_CHARS
  // bytes; QML only ever receives a bounded, regular-file document. The
  // FileView below is a pure change watcher (blockLoading) plus the atomic
  // write surface for the editor.
  function loadConfig() {
    if (readerProc.running) return
    readerProc.command = [
      "python3", "-c",
      "import os,stat,sys\n" +
      "p=sys.argv[1]; cap=" + PieModel.MAX_FILE_CHARS + "\n" +
      "try:\n" +
      "  fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)\n" +
      "except OSError as e:\n" +
      "  sys.stdout.write('ERR:'+{2:'NOFILE',40:'SYMLINK'}.get(e.errno,'OPEN'+str(e.errno)))\n" +
      "  raise SystemExit\n" +
      "try:\n" +
      "  st=os.fstat(fd)\n" +
      "  if not stat.S_ISREG(st.st_mode): sys.stdout.write('ERR:NOTREG')\n" +
      "  elif st.st_size>cap: sys.stdout.write('ERR:TOOBIG')\n" +
      "  else:\n" +
      "    d=os.read(fd,cap+1)\n" +
      "    sys.stdout.write('ERR:TOOBIG' if len(d)>cap else d.decode('utf-8','replace'))\n" +
      "finally:\n" +
      "  os.close(fd)\n",
      configFile.path
    ]
    readerProc.running = true
  }

  Process {
    id: readerProc
    command: ["true"]

    stdout: StdioCollector {
      id: readerOut
      onStreamFinished: {
        root.configReady = true
        var out = readerOut.text
        if (out.lastIndexOf("ERR:", 0) === 0) {
          var code = out.substring(4)
          if (code === "NOFILE") {
            // No user config yet — the demo wheel doubles as the hint.
            configError = ""
            wheelMode = "click"
            rootWheel = PieModel.demoWheel()
            if (root.opened && !root.editorOpen && root.navStack.length === 0) {
              root.wheel = rootWheel
              root.bumpWheel()
            }
          } else if (code === "SYMLINK") {
            root.rejectConfig("config path is a symlink; refusing to follow it")
          } else if (code === "NOTREG") {
            root.rejectConfig("config path is not a regular file")
          } else if (code === "TOOBIG") {
            root.rejectConfig(PieModel.limitError(
              "over " + PieModel.MAX_FILE_CHARS + " characters"))
          } else {
            root.rejectConfig("config could not be read (" + code + ")")
          }
          return
        }
        root.applyConfig(out)
      }
    }
  }

  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy/extensions/omas.jsonc"
    // Watch for replacements and serve atomic writes, but never load the
    // document here — the bounded reader above owns reads.
    watchChanges: true
    preload: false
    blockLoading: true
    atomicWrites: true
    printErrors: false
    onFileChanged: root.loadConfig()
  }

  // Cursor read for cursor-relative summoning: hyprctl reports the global
  // layout position in "X, Y" form. Any failure (missing hyprctl, empty or
  // malformed output) falls back to the panel center via finishOpen().
  Process {
    id: cursorProc
    command: ["hyprctl", "cursorpos"]

    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var t = text.trim()
          var comma = t.indexOf(",")
          if (comma > 0) {
            var gx = parseFloat(t.substring(0, comma))
            var gy = parseFloat(t.substring(comma + 1))
            if (isFinite(gx) && isFinite(gy)) {
              var p = root.localCursorCenter(gx, gy)
              if (p) root.cursorAt = p
            }
          }
        } catch (e) {
          console.warn("Omas: cursor read failed:", e)
        }
        root.finishOpen()
      }
    }
  }

  // Never let a wedged cursor read block the summon for long.
  Timer {
    id: cursorFallback
    interval: 250
    onTriggered: root.finishOpen()
  }

  // Fresh cursor read for pick(); empty or failed output dismisses.
  Process {
    id: pickProc
    command: ["hyprctl", "cursorpos"]

    stdout: StdioCollector {
      onStreamFinished: root.finishPick(text)
    }
  }

  Component.onCompleted: loadConfig()

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
      // Centered on the summon point (or the panel center). scale is
      // applied around Item.Center, so the visual wheel stays centered on
      // (x + width/2, y + height/2) as it shrinks near screen edges.
      x: root.openAt.x >= 0 ? root.openAt.x - width / 2 : (parent.width - width) / 2
      y: root.openAt.y >= 0 ? root.openAt.y - height / 2 : (parent.height - height) / 2
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
          onPositionChanged: function(mouse) {
            root.hoveredIndex = root.wedgeIndexAt(mouse.x, mouse.y)
          }
          onExited: root.hoveredIndex = -1
          onClicked: if (root.hoveredIndex >= 0) {
            root.clickUsed = true
            root.openItem(root.hoveredIndex)
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
            onPositionChanged: root.hoveredIndex = -1
            // Deeper wheels: back. Root wheel: the hub is the door to
            // the settings/editor panel.
            onClicked: {
              root.clickUsed = true
              if (root.canGoBack) root.goBack()
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
              text: root.canGoBack ? "back" : "settings"
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
