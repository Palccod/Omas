import QtQuick
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

Item {
  id: editor

  // Set by Menu.qml via beginEdit().
  property var itemsTree: []
  property string selectionMode: "click"

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
    selectionMode = mode
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
    var json = PieModel.serializeConfig(
      { selectionMode: selectionMode }, itemsTree)
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

  BorderSurface {
    id: card
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.gapsOut * 2, Style.space(480))
    height: Math.min(parent.height - Style.gapsOut * 4, Style.space(600))
    radius: Style.cornerRadius
    color: Color.menu.background
    borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
    padding: Style.spacing.md

    MouseArea { anchors.fill: parent; onClicked: {} }

    // ---- browse view ----------------------------------------------------
    Column {
      anchors.fill: parent
      anchors.margins: card.padding
      spacing: Style.spacing.sm
      visible: !editor.formOpen

      Row {
        id: browseHeader
        width: parent.width
        spacing: Style.spacing.sm

        Column {
          width: parent.width - saveButton.width - cancelButton.width - 2 * parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          Text {
            width: parent.width
            text: "Wheel editor"
            color: editor.foreground
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.heading
            font.weight: Font.DemiBold
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            text: editor.levelPath()
            color: editor.dimmed
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
        }
        Button {
          id: cancelButton
          text: "Cancel"
          onClicked: editor.editorCanceled()
        }
        Button {
          id: saveButton
          text: "Save & close"
          active: true
          onClicked: editor.saveAll()
        }
      }

      Text {
        id: saveErrorText
        width: parent.width
        visible: editor.saveError !== ""
        text: editor.saveError
        color: Color.urgent
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Dropdown {
        id: selectionDropdown
        width: parent.width
        label: "Selection"
        value: editor.selectionMode
        options: [{ value: "click", label: "Click" }, { value: "stroke", label: "Stroke (gesture)" }]
        onChanged: function(v) { editor.selectionMode = v }
      }

      Row {
        id: levelRow
        width: parent.width
        spacing: Style.spacing.sm

        Button {
          id: levelUpButton
          text: editor.levelStack.length > 0 ? "‹ " + (editor.levelStack.length > 1 ? editor.levelStack[editor.levelStack.length - 2].name : "root") : "root"
          visible: editor.levelStack.length > 0
          onClicked: editor.goLevelUp()
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - parent.spacing - (levelUpButton.visible ? levelUpButton.width : 0)
          text: editor.currentItems.length + (editor.currentItems.length === 1 ? " item" : " items")
          color: editor.dimmed
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideLeft
        }
      }

      ListView {
        id: listView
        width: parent.width
        height: parent.height - browseHeader.height - selectionDropdown.height
          - levelRow.height - addButton.height
          - (saveErrorText.visible ? saveErrorText.height + parent.spacing : 0)
          - 4 * parent.spacing
        clip: true
        spacing: Style.spacing.xs
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: browseRow
          width: listView.width
          height: Style.space(46)
          radius: Style.cornerRadius
          color: rowMouse.containsMouse ? Style.hoverFill : "transparent"

          required property int index
          required property var modelData
          readonly property var item: browseRow.modelData
          readonly property bool wheel: editor.isWheel(browseRow.modelData)

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: editor.openForm(browseRow.index, false)
          }

          Text {
            visible: browseRow.item.icon.charAt(0) !== "/"
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: browseRow.item.icon
            font.pixelSize: Style.font.title
          }

          Image {
            visible: browseRow.item.icon.charAt(0) === "/"
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            width: Style.font.iconLarge
            height: width
            fillMode: Image.PreserveAspectFit
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
            source: browseRow.item.icon.charAt(0) === "/" ? browseRow.item.icon : ""
            asynchronous: true
          }

          Column {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(48)
            anchors.right: actionsRow.left
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter

            Text {
              width: parent.width
              text: browseRow.item.name
              color: editor.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
              font.weight: Font.Medium
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              text: browseRow.wheel ? (browseRow.item.children.length + (browseRow.item.children.length === 1 ? " item" : " items"))
                : ("→ " + browseRow.item.command)
              color: editor.dimmed
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
          }

          Row {
            id: actionsRow
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Button {
              iconText: "›"
              visible: browseRow.wheel
              onClicked: editor.drillInto(browseRow.index)
            }
            Button {
              iconText: "✎"
              onClicked: editor.openForm(browseRow.index, false)
            }
            Button {
              iconText: "✕"
              onClicked: editor.requestDelete(browseRow.index)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: listView.count === 0
          text: "Empty — add an item below"
          color: editor.dimmed
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }
      }

      Button {
        id: addButton
        width: parent.width
        text: "+  Add item"
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
        spacing: Style.spacing.sm

        Text {
          text: editor.formCtx && editor.formCtx.isNew ? "Add item" : "Edit item"
          color: editor.foreground
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.heading
          font.weight: Font.DemiBold
        }
        Text {
          visible: editor.formStack.length >= 2
          text: editor.formStack.length >= 2
            ? "inside “" + (editor.formStack[editor.formStack.length - 2].item.name || "wheel") + "”"
            : ""
          color: editor.dimmed
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          text: "Name"
          color: editor.dimmed
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }
        TextField {
          id: nameField
          width: parent.width
          placeholderText: "Name shown under the icon"
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

        Text {
          width: parent.width
          text: "Icon — emoji, glyph, or /path/to/image"
          color: editor.dimmed
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }
        Row {
          id: iconRow
          width: parent.width
          spacing: Style.spacing.sm

          Rectangle {
            width: Style.space(44)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: Style.hoverFill
            border.color: Color.menu.border
            border.width: 1

            Text {
              visible: editor.formItem && editor.formItem.icon.charAt(0) !== "/"
              anchors.centerIn: parent
              text: editor.formItem ? editor.formItem.icon : ""
              font.pixelSize: Style.font.title
            }
            Image {
              visible: editor.formItem && editor.formItem.icon.charAt(0) === "/"
              anchors.centerIn: parent
              width: Style.font.iconLarge
              height: width
              fillMode: Image.PreserveAspectFit
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              source: editor.formItem && editor.formItem.icon.charAt(0) === "/" ? editor.formItem.icon : ""
              asynchronous: true
            }
          }

          TextField {
            id: iconField
            width: parent.width - parent.spacing - Style.space(44)
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "🌐"
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
          onClicked: editor.formKind = editor.formKind === "wheel" ? "command" : "wheel"
        }

        Column {
          id: commandSection
          width: parent.width
          spacing: Style.spacing.sm
          visible: editor.formKind === "command"

          Text {
            width: parent.width
            text: "Command"
            color: editor.dimmed
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
          TextField {
            id: commandField
            width: parent.width
            placeholderText: "e.g. firefox --private-window"
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
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.spacing.sm
        layoutDirection: Qt.RightToLeft

        Button {
          text: "Save"
          active: true
          onClicked: editor.saveForm()
        }
        Button {
          text: "Cancel"
          onClicked: editor.cancelForm()
        }
      }

      // A sub-wheel's contents, inline: the same list UI as the browse
      // page. Adding or editing an item here pushes a nested form whose
      // Save/Cancel comes back to this one.
      Column {
        id: childSection
        anchors.top: formTop.bottom
        anchors.topMargin: Style.spacing.md
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: formButtons.top
        anchors.bottomMargin: Style.spacing.md
        visible: editor.formKind === "wheel"
        spacing: Style.spacing.sm

        Text {
          id: childHeader
          width: parent.width
          text: editor.formItem && editor.formItem.children
            ? editor.formItem.children.length + (editor.formItem.children.length === 1 ? " item" : " items") + " inside"
            : ""
          color: editor.dimmed
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }

        ListView {
          id: childList
          width: parent.width
          height: parent.height - childHeader.height - childAddButton.height - 2 * parent.spacing
          clip: true
          spacing: Style.spacing.xs
          boundsBehavior: Flickable.StopAtBounds
          model: editor.formItem && Array.isArray(editor.formItem.children) ? editor.formItem.children : []

          delegate: Rectangle {
            id: childRow
            width: childList.width
            height: Style.space(46)
            radius: Style.cornerRadius
            color: childRowMouse.containsMouse ? Style.hoverFill : "transparent"

            required property int index
            required property var modelData
            readonly property var item: childRow.modelData
            readonly property bool wheel: editor.isWheel(childRow.modelData)

            MouseArea {
              id: childRowMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: editor.openChildForm(childRow.index, false)
            }

            Text {
              visible: childRow.item.icon.charAt(0) !== "/"
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              text: childRow.item.icon
              font.pixelSize: Style.font.title
            }

            Image {
              visible: childRow.item.icon.charAt(0) === "/"
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              width: Style.font.iconLarge
              height: width
              fillMode: Image.PreserveAspectFit
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              source: childRow.item.icon.charAt(0) === "/" ? childRow.item.icon : ""
              asynchronous: true
            }

            Column {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(48)
              anchors.right: childActionsRow.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter

              Text {
                width: parent.width
                text: childRow.item.name
                color: editor.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
                font.weight: Font.Medium
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: childRow.wheel ? (childRow.item.children.length + (childRow.item.children.length === 1 ? " item" : " items"))
                  : ("→ " + childRow.item.command)
                color: editor.dimmed
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }
            }

            Row {
              id: childActionsRow
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs

              Button {
                iconText: "✎"
                onClicked: editor.openChildForm(childRow.index, false)
              }
              Button {
                iconText: "✕"
                onClicked: editor.requestChildDelete(childRow.index)
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: childList.count === 0
            text: "Empty — add an item below"
            color: editor.dimmed
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
        }

        Button {
          id: childAddButton
          width: parent.width
          text: "+  Add item"
          onClicked: editor.openChildForm(editor.formItem && editor.formItem.children ? editor.formItem.children.length : 0, true)
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
    fontFamily: Style.font.menuFamily
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
