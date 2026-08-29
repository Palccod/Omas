import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "PieModel.js" as PieModel

// Omas wheel editor — opened by Menu.qml's enterEditor() (hub click on the
// root wheel or the {"edit": true} summon payload). Edits a working copy of
// the tree and writes ~/.config/omarchy/extensions/omas.jsonc on save.
//
// Two views inside the card: the browse list (with a level stack for
// drilling into sub-wheels) and the item form. The form is itself a stack:
// a sub-wheel form shows its items inline — an "+ Add item" button plus a
// list, exactly like the browse page — and adding/editing those items
// pushes a nested form whose Save/Cancel returns to the parent form, so
// wheels can be built arbitrarily deep without leaving the form.
//
// Cancel only ever steps back one level; at the top it leaves the editor
// and returns to the menu wheel (Menu.qml keeps the menu open). Saving
// rewrites the file, so hand-written comments in it are lost.
//
// Styling follows the shell's panel vocabulary (section headers,
// separators, segmented choices, bordered controls) like the built-in bar
// panels, while staying a menu overlay rather than a bar panel.

Item {
  id: editor

  // Set by Menu.qml via beginEdit().
  property var itemsTree: []

  // Summon mode being edited ("click" or "hold"). Menu.qml passes the
  // current value into beginEdit() and reads it back in saveFromEditor().
  property string summonMode: "click"

  signal editorSaved(string json)
  signal editorCanceled()

  // ---- browse state ------------------------------------------------------
  // A stack of parent levels; currentItems references the array being
  // listed (mutated in place inside itemsTree).
  property var levelStack: []
  property var currentItems: []
  property string currentName: "root"

  // ---- form stack ---------------------------------------------------------
  // Each entry: { item, kind, isNew, index }. Depth 1 edits an item of the
  // browse list; deeper entries edit a child of the wheel form one below,
  // at `index` of that wheel's children.
  property var formStack: []
  property string formKind: "command"   // mirrors the top entry's kind; flipped by the toggle
  property bool fieldsSilent: false     // suppress write-back while fields are (re)populated
  property int deleteIndex: -1          // pending delete in the browse list
  property int deleteChildIndex: -1     // pending delete in the form's inline children list
  property string saveError: ""         // set when Save & close exceeds a budget

  readonly property bool formOpen: formStack.length > 0
  readonly property var formCtx: formStack.length > 0 ? formStack[formStack.length - 1] : null
  readonly property var formItem: formCtx ? formCtx.item : null

  function beginEdit(tree, mode) {
    itemsTree = tree
    summonMode = mode === "hold" ? "hold" : "click"
    levelStack = []
    currentItems = itemsTree
    currentName = "root"
    formStack = []
    deleteIndex = -1
    deleteChildIndex = -1
    saveError = ""
    refreshList()
  }

  function refreshList() {
    listView.model = null
    listView.model = currentItems
  }

  function levelPath() {
    var parts = ["root"]
    for (var i = 0; i < levelStack.length; i++) parts.push(levelStack[i].name)
    return parts.join("  ›  ")
  }

  // Children delivered through a ListView's model arrive as array-like
  // objects that fail Array.isArray(), so judge by content instead: a node
  // is a wheel when it has children at all beyond commands.
  function isWheel(item) {
    return !!item && !!item.children
      && (item.children.length > 0 || !item.command)
  }

  // ---- form stack helpers -------------------------------------------------

  // Fields are populated imperatively (never bound): onTextChanged writes
  // back through patchTopItem, so a text binding would loop.
  function syncFieldsTo(item) {
    fieldsSilent = true
    nameField.text = item.name || ""
    iconField.text = item.icon || ""
    commandField.text = item.command || ""
    fieldsSilent = false
  }

  // Replace the top form entry with an updated copy. The whole stack is
  // reassigned so bindings on formStack/formItem see the change.
  function patchTopItem(patch) {
    if (!formCtx) return
    var next = JSON.parse(JSON.stringify(formCtx.item))
    Object.assign(next, patch)
    var s = formStack.slice(0, -1)
    s.push({ item: next, kind: formCtx.kind, isNew: formCtx.isNew, index: formCtx.index })
    formStack = s
  }

  function pushForm(base, isNew, index, kind) {
    var item = base ? JSON.parse(JSON.stringify(base)) : { name: "", icon: "", command: "", children: [] }
    if (!Array.isArray(item.children)) item.children = []
    syncFieldsTo(item)
    formKind = kind
    formStack = formStack.concat([{ item: item, kind: kind, isNew: isNew, index: index }])
  }

  function openForm(index, isNew) {
    var base = isNew ? null : currentItems[index]
    pushForm(base, isNew, index, base && isWheel(base) ? "wheel" : "command")
  }

  function openChildForm(index, isNew) {
    var base = !isNew && formItem && formItem.children ? formItem.children[index] : null
    pushForm(base, isNew, index, base && isWheel(base) ? "wheel" : "command")
  }

  function saveForm() {
    if (!formCtx) return
    var item = {
      name: (formItem.name || "").length > 0 ? formItem.name : "Item",
      icon: formItem.icon || ""
    }
    if (formKind === "wheel") item.children = formItem.children || []
    else item.command = formItem.command || ""

    if (formStack.length >= 2) {
      // Nested form: hand the saved item to the parent wheel form and step
      // back up so the parent's inline list shows the result.
      var parent = formStack[formStack.length - 2]
      var pItem = JSON.parse(JSON.stringify(parent.item))
      if (!Array.isArray(pItem.children)) pItem.children = []
      if (formCtx.isNew || formCtx.index < 0 || formCtx.index >= pItem.children.length)
        pItem.children.push(item)
      else
        pItem.children[formCtx.index] = item
      var s = formStack.slice(0, -2)
      s.push({ item: pItem, kind: parent.kind, isNew: parent.isNew, index: parent.index })
      formKind = parent.kind
      formStack = s
      syncFieldsTo(pItem)
    } else {
      if (formCtx.isNew) currentItems.push(item)
      else currentItems[formCtx.index] = item
      formStack = []
      refreshList()
    }
  }

  // Cancel discards this form and shows the one below (or the browse list).
  function cancelForm() {
    if (formStack.length === 0) return
    formStack = formStack.slice(0, -1)
    if (formStack.length > 0) {
      formKind = formStack[formStack.length - 1].kind
      syncFieldsTo(formStack[formStack.length - 1].item)
    }
  }

  // ---- deletes -------------------------------------------------------------

  function requestDelete(index) {
    deleteIndex = index
    deleteChildIndex = -1
  }

  function requestChildDelete(index) {
    deleteChildIndex = index
    deleteIndex = -1
  }

  function confirmDelete() {
    if (deleteIndex >= 0 && deleteIndex < currentItems.length)
      currentItems.splice(deleteIndex, 1)
    deleteIndex = -1
    refreshList()
  }

  function confirmDeleteChild() {
    if (deleteChildIndex >= 0 && formItem && Array.isArray(formItem.children)
        && deleteChildIndex < formItem.children.length) {
      var children = JSON.parse(JSON.stringify(formItem.children))
      children.splice(deleteChildIndex, 1)
      patchTopItem({ children: children })
    }
    deleteChildIndex = -1
  }

  // ---- navigation ----------------------------------------------------------

  function drillInto(index) {
    levelStack = levelStack.concat([{ name: currentItems[index].name, items: currentItems }])
    currentItems = currentItems[index].children
    currentName = levelStack[levelStack.length - 1].name
    refreshList()
  }

  function goLevelUp() {
    if (levelStack.length === 0) return
    var top = levelStack[levelStack.length - 1]
    currentItems = top.items
    currentName = levelStack.length > 1 ? levelStack[levelStack.length - 2].name : "root"
    levelStack = levelStack.slice(0, -1)
    refreshList()
  }

  function saveAll() {
    // serializeConfig returns "" when the tree exceeds any budget; an
    // over-budget wheel is never written to the config file.
    var json = PieModel.serializeConfig(itemsTree)
    if (json === "") {
      saveError = "Wheel exceeds limits — max " + PieModel.MAX_ITEMS + " items, "
        + PieModel.MAX_DEPTH + " levels, 256 KiB. Remove some items first."
      return
    }
    saveError = ""
    formStack = []
    editorSaved(json)
  }

  // Escape, from Menu.qml's keyCatcher or from a focused field inside the
  // editor (event propagation reaches this Item). Steps back one level:
  // dialog → form → browse list → back to the menu wheel.
  function handleKey(event) {
    if (deleteDialog.opened) return deleteDialog.handleKey(event)
    if (event.key === Qt.Key_Escape) {
      if (formOpen) cancelForm()
      else editorCanceled()
      return true
    }
    return false
  }

  Keys.onEscapePressed: function(event) {
    editor.handleKey(event)
    event.accepted = true
  }

  readonly property color foreground: Color.menu.text
  readonly property color dimmed: Util.alpha(Color.menu.text, 0.55)
  readonly property color accent: Color.accent

  // Circular badge that renders an item's icon — emoji/glyph as text, or
  // an image when the icon is an absolute path. Shared by the browse rows,
  // the form's inline children rows, and the form's icon preview.
  component IconChip: Item {
    id: chip

    property string icon: ""
    property real chipSize: Style.space(34)

    width: chipSize
    height: chipSize

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: Style.hoverFill
      border.color: Color.menu.border
      border.width: 1
    }

    Text {
      visible: chip.icon.charAt(0) !== "/"
      anchors.centerIn: parent
      text: visible ? chip.icon : ""
      color: editor.foreground
      font.pixelSize: Math.round(chip.chipSize * 0.52)
    }

    Image {
      visible: chip.icon.charAt(0) === "/"
      anchors.centerIn: parent
      width: Math.round(chip.chipSize * 0.7)
      height: width
      fillMode: Image.PreserveAspectFit
      sourceSize.width: width * Screen.devicePixelRatio
      sourceSize.height: height * Screen.devicePixelRatio
      source: visible ? chip.icon : ""
      asynchronous: true
    }
  }

  // Field label in the body font, like the input labels in shell panels.
  component FieldLabel: Text {
    color: editor.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  // One row of an item list: icon chip, name + detail, and the row actions.
  // Used by both the browse list and a wheel form's inline children.
  component ItemRow: Rectangle {
    id: row

    property var item: ({})
    property bool wheel: false
    property var list
    property int rowIndex: 0
    property bool allowDrill: false

    signal activated(int index)
    signal drilled(int index)
    signal edited(int index)
    signal removed(int index)

    width: row.list ? row.list.width : 0
    height: Style.space(46)
    radius: Style.cornerRadius
    color: rowMouse.containsMouse ? Style.hoverFill : "transparent"

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: row.activated(row.rowIndex)
    }

    IconChip {
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      icon: row.item.icon || ""
      chipSize: Style.space(34)
    }

    Column {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(34) + Style.spacing.lg
      anchors.right: rowActions.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter

      Text {
        width: parent.width
        text: row.item.name || ""
        color: editor.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.weight: Font.Medium
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        text: row.wheel
          ? ((row.item.children ? row.item.children.length : 0)
            + ((row.item.children && row.item.children.length === 1) ? " item" : " items"))
          : ("→ " + (row.item.command || ""))
        color: editor.dimmed
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }

    Row {
      id: rowActions
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Button {
        iconText: "›"
        tooltipText: "Open wheel"
        visible: row.allowDrill && row.wheel
        height: Style.spacing.controlHeight
        bordered: true
        focusable: true
        foreground: editor.foreground
        accent: editor.accent
        onClicked: row.drilled(row.rowIndex)
      }
      Button {
        iconText: "✎"
        tooltipText: "Edit"
        height: Style.spacing.controlHeight
        bordered: true
        focusable: true
        foreground: editor.foreground
        accent: editor.accent
        onClicked: row.edited(row.rowIndex)
      }
      Button {
        iconText: "✕"
        tooltipText: "Remove"
        height: Style.spacing.controlHeight
        bordered: true
        focusable: true
        foreground: editor.foreground
        accent: editor.accent
        onClicked: row.removed(row.rowIndex)
      }
    }
  }

  BorderSurface {
    id: card
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.gapsOut * 2, Style.space(480))
    height: Math.min(parent.height - Style.gapsOut * 4, Style.space(640))
    radius: Style.cornerRadius
    color: Color.menu.background
    borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
    padding: Style.space(14)

    MouseArea { anchors.fill: parent; onClicked: {} }

    // ---- browse view ----------------------------------------------------
    Item {
      anchors.fill: parent
      anchors.margins: card.padding
      visible: !editor.formOpen

      Column {
        id: browseTop
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(8)

        Row {
          id: browseHeader
          width: parent.width
          spacing: Style.spacing.sm

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: ""
            color: editor.accent
            font.family: Style.font.family
            font.pixelSize: Style.space(26)
          }

          Column {
            width: parent.width - editorActions.implicitWidth - Style.space(26) - 2 * parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
              width: parent.width
              text: "Wheel editor"
              color: editor.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              text: editor.levelPath()
              color: editor.dimmed
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
          }

          Row {
            id: editorActions
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Button {
              text: "Cancel"
              tooltipText: "Back to the wheel"
              height: Style.spacing.controlHeight
              bordered: true
              focusable: true
              foreground: editor.foreground
              accent: editor.accent
              onClicked: editor.editorCanceled()
            }
            Button {
              text: "Save & close"
              tooltipText: "Write the wheel to omas.jsonc"
              height: Style.spacing.controlHeight
              active: true
              bordered: true
              focusable: true
              foreground: editor.foreground
              accent: editor.accent
              onClicked: editor.saveAll()
            }
          }
        }

        // Summon mode switch — a root-page-only setting, applied on save.
        Column {
          id: modeRow
          width: parent.width
          spacing: 2
          visible: editor.levelStack.length === 0

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            FieldLabel {
              width: parent.width - modeButtons.implicitWidth - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              text: "Summon mode"
              font.weight: Font.Medium
            }

            Row {
              id: modeButtons
              spacing: Style.space(4)

              Button {
                text: "Click"
                tooltipText: "One key press toggles the wheel; point and click to run items"
                height: Style.spacing.controlHeight
                active: editor.summonMode === "click"
                bordered: true
                focusable: true
                foreground: editor.foreground
                accent: editor.accent
                onClicked: editor.summonMode = "click"
              }
              Button {
                text: "Hold"
                tooltipText: "Hold the key, flick to an item, release to launch it"
                height: Style.spacing.controlHeight
                active: editor.summonMode === "hold"
                bordered: true
                focusable: true
                foreground: editor.foreground
                accent: editor.accent
                onClicked: editor.summonMode = "hold"
              }
            }
          }

          Text {
            width: parent.width
            text: editor.summonMode === "hold"
              ? "Hold the key and release over an item to launch it. Hold mode also needs the release keybind — see the README."
              : "One key press opens the wheel; point and click to run an item."
            color: editor.dimmed
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Text {
          id: saveErrorText
          width: parent.width
          visible: editor.saveError !== ""
          text: editor.saveError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Item {
          id: levelRow
          width: parent.width
          height: Math.max(levelUpButton.visible ? levelUpButton.height : 0,
            levelCount.implicitHeight)

          Button {
            id: levelUpButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: "‹"
            text: editor.levelStack.length > 0
              ? (editor.levelStack.length > 1
                ? editor.levelStack[editor.levelStack.length - 2].name : "root")
              : ""
            tooltipText: "Back one level"
            visible: editor.levelStack.length > 0
            height: Style.spacing.controlHeight
            bordered: true
            focusable: true
            foreground: editor.foreground
            accent: editor.accent
            onClicked: editor.goLevelUp()
          }
          Text {
            id: levelCount
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: editor.currentItems.length + (editor.currentItems.length === 1 ? " item" : " items")
            color: editor.dimmed
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
          }
        }
      }

      ListView {
        id: listView
        anchors.top: browseTop.bottom
        anchors.topMargin: Style.space(8)
        anchors.bottom: addButton.top
        anchors.bottomMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        spacing: Style.space(4)
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        delegate: ItemRow {
            required property int index
            required property var modelData

            list: listView
            rowIndex: index
            item: modelData
            wheel: editor.isWheel(modelData)
            allowDrill: true
            onActivated: function(i) { editor.openForm(i, false) }
            onDrilled: function(i) { editor.drillInto(i) }
            onEdited: function(i) { editor.openForm(i, false) }
            onRemoved: function(i) { editor.requestDelete(i) }
        }

        Text {
          anchors.centerIn: parent
          visible: listView.count === 0
          text: "No items yet — add one below"
          color: editor.dimmed
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Button {
        id: addButton
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.spacing.controlHeight
        iconText: "+"
        text: "Add item"
        tooltipText: "Add an item to this wheel"
        bordered: true
        focusable: true
        foreground: editor.foreground
        accent: editor.accent
        onClicked: editor.openForm(currentItems.length, true)
      }
    }

    // ---- item form (stack) -----------------------------------------------
    Item {
      anchors.fill: parent
      anchors.margins: card.padding
      visible: editor.formOpen

      Column {
        id: formTop
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(8)

        Row {
          width: parent.width
          spacing: Style.spacing.sm

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: editor.formCtx && editor.formCtx.isNew ? "\uF067" : "\uF044"
            color: editor.accent
            font.family: Style.font.family
            font.pixelSize: Style.space(22)
          }

          Column {
            width: parent.width - Style.space(22) - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
              width: parent.width
              text: editor.formCtx && editor.formCtx.isNew ? "Add item" : "Edit item"
              color: editor.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              visible: editor.formStack.length >= 2
              text: editor.formStack.length >= 2
                ? "inside “" + (editor.formStack[editor.formStack.length - 2].item.name || "wheel") + "”"
                : ""
              color: editor.dimmed
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
          }
        }

        FieldLabel {
          width: parent.width
          text: "Name"
        }
        TextField {
          id: nameField
          width: parent.width
          placeholderText: "Name shown under the icon"
          foreground: editor.foreground
          accent: editor.accent
          // The kit's TextField has no maxLength; enforce the budget by
          // truncating here (the write-back fires again with bounded text).
          onTextChanged: {
            if (editor.fieldsSilent) return
            if (text.length > PieModel.MAX_NAME_CHARS) {
              nameField.text = text.slice(0, PieModel.MAX_NAME_CHARS)
              return
            }
            editor.patchTopItem({ name: text })
          }
        }

        FieldLabel {
          width: parent.width
          text: "Icon"
        }
        Row {
          id: iconRow
          width: parent.width
          spacing: Style.spacing.sm

          IconChip {
            width: Style.space(44)
            height: width
            anchors.verticalCenter: parent.verticalCenter
            icon: editor.formItem ? editor.formItem.icon : ""
            chipSize: Style.space(44)
          }

          TextField {
            id: iconField
            width: parent.width - parent.spacing - Style.space(44)
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Emoji, glyph, or /path/to/image"
            foreground: editor.foreground
            accent: editor.accent
            onTextChanged: {
              if (editor.fieldsSilent) return
              if (text.length > PieModel.MAX_ICON_CHARS) {
                iconField.text = text.slice(0, PieModel.MAX_ICON_CHARS)
                return
              }
              editor.patchTopItem({ icon: text })
            }
          }
        }

        Toggle {
          width: parent.width
          label: "Sub-wheel"
          description: editor.formKind === "wheel"
            ? "Opens a nested wheel — manage its items below"
            : "Runs a command when selected"
          checked: editor.formKind === "wheel"
          foreground: editor.foreground
          accent: editor.accent
          onClicked: editor.formKind = editor.formKind === "wheel" ? "command" : "wheel"
        }

        PanelSeparator { width: parent.width; foreground: editor.foreground }

        Column {
          id: commandSection
          width: parent.width
          spacing: Style.spacing.sm
          visible: editor.formKind === "command"

          FieldLabel {
            width: parent.width
            text: "Command"
          }
          TextField {
            id: commandField
            width: parent.width
            placeholderText: "e.g. firefox --private-window"
            foreground: editor.foreground
            accent: editor.accent
            onTextChanged: {
              if (editor.fieldsSilent) return
              if (text.length > PieModel.MAX_COMMAND_CHARS) {
                commandField.text = text.slice(0, PieModel.MAX_COMMAND_CHARS)
                return
              }
              editor.patchTopItem({ command: text })
            }
          }
        }
      }

      Row {
        id: formButtons
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(6)

        Button {
          width: (parent.width - parent.spacing) / 2
          height: Style.spacing.controlHeight
          text: "Cancel"
          tooltipText: "Discard and step back"
          bordered: true
          focusable: true
          foreground: editor.foreground
          accent: editor.accent
          onClicked: editor.cancelForm()
        }
        Button {
          width: (parent.width - parent.spacing) / 2
          height: Style.spacing.controlHeight
          text: "Save"
          tooltipText: "Keep this item"
          active: true
          bordered: true
          focusable: true
          foreground: editor.foreground
          accent: editor.accent
          onClicked: editor.saveForm()
        }
      }

      // A sub-wheel's contents, inline: the same list UI as the browse
      // page. Adding or editing an item here pushes a nested form whose
      // Save/Cancel comes back to this one.
      Column {
        id: childSection
        anchors.top: formTop.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: formButtons.top
        anchors.bottomMargin: Style.space(8)
        visible: editor.formKind === "wheel"
        spacing: Style.space(8)

        PanelSectionHeader {
          id: childSectionHeader
          width: parent.width
          text: "ITEMS INSIDE"
          foreground: editor.foreground
        }

        Text {
          id: childHeader
          width: parent.width
          text: editor.formItem && editor.formItem.children
            ? editor.formItem.children.length + (editor.formItem.children.length === 1 ? " item" : " items") + " in this wheel"
            : ""
          color: editor.dimmed
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Button {
          id: childAddButton
          width: parent.width
          height: Style.spacing.controlHeight
          iconText: "+"
          text: "Add item"
          tooltipText: "Add an item to this wheel"
          bordered: true
          focusable: true
          foreground: editor.foreground
          accent: editor.accent
          onClicked: editor.openChildForm(editor.formItem && editor.formItem.children ? editor.formItem.children.length : 0, true)
        }

        ListView {
          id: childList
          width: parent.width
          height: parent.height - childSectionHeader.height - childHeader.height
            - childAddButton.height - 3 * parent.spacing
          clip: true
          spacing: Style.space(4)
          boundsBehavior: Flickable.StopAtBounds
          model: editor.formItem && Array.isArray(editor.formItem.children) ? editor.formItem.children : []
          QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

          delegate: ItemRow {
              required property int index
              required property var modelData

              list: childList
              rowIndex: index
              item: modelData
              wheel: editor.isWheel(modelData)
              allowDrill: false
              onActivated: function(i) { editor.openChildForm(i, false) }
              onEdited: function(i) { editor.openChildForm(i, false) }
              onRemoved: function(i) { editor.requestChildDelete(i) }
          }

          Text {
            anchors.centerIn: parent
            visible: childList.count === 0
            text: "No items yet — add one below"
            color: editor.dimmed
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

      }
    }
  }

  // The dialog fills the editor so its scrim covers the card and the
  // message centers (its content is sized by anchors.fill, not centerIn).
  ConfirmDialog {
    id: deleteDialog
    anchors.fill: parent
    opened: editor.deleteIndex >= 0 || editor.deleteChildIndex >= 0
    message: {
      var it = null
      if (editor.deleteChildIndex >= 0 && editor.formItem && Array.isArray(editor.formItem.children))
        it = editor.formItem.children[editor.deleteChildIndex] || null
      else if (editor.deleteIndex >= 0)
        it = editor.currentItems[editor.deleteIndex] || null
      return it ? ("Remove \"" + it.name + "\"" + (editor.isWheel(it) ? " and everything inside it?" : "?")) : ""
    }
    confirmText: "Remove"
    background: Color.menu.background
    foreground: editor.foreground
    scrim: Util.alpha(Color.menu.background, 0.6)
    selectedBackground: Style.selectedAccentFill
    selectedText: editor.accent
    fontFamily: Style.font.family
    cornerRadius: Style.cornerRadius
    onCanceled: {
      editor.deleteIndex = -1
      editor.deleteChildIndex = -1
    }
    onConfirmed: {
      if (editor.deleteChildIndex >= 0) editor.confirmDeleteChild()
      else editor.confirmDelete()
    }
  }
}
