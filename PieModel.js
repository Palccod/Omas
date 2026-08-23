// Omas wheel tree model: parse + validate the user's JSONC definition.
//
// The config is a tree of nodes. A node with "children" opens a sub-wheel;
// a node with "command" runs it through bash. "icon" is an emoji, a text
// glyph, or an absolute path to an image.

.pragma library

function stripJsonc(raw) {
  return String(raw || "")
    .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
    .replace(/,(\s*[}\]])/g, "$1")
}

// Normalize one raw node. Returns null for nodes that can do nothing.
// A node with an explicit (possibly empty) "children" array is kept as an
// empty sub-wheel — the editor relies on this so new wheels survive a
// save/reload round-trip before their first child is added.
function normalizeItem(raw, index) {
  var value = raw || {}
  var hadChildren = Array.isArray(value.children)
  var children = []
  if (hadChildren) {
    for (var i = 0; i < value.children.length; i++) {
      var child = normalizeItem(value.children[i], i)
      if (child) children.push(child)
    }
  }
  var command = typeof value.command === "string" ? value.command
    : (typeof value.action === "string" ? value.action : "")
  if (!command && !hadChildren) return null
  return {
    name: String(value.name || value.label || ("Item " + (index + 1))),
    icon: String(value.icon || ""),
    command: command,
    children: children
  }
}

// Parse a full config document. Accepts either a top-level array or an
// object with an "items" (or "children") array. Returns
// { items, error, selectionMode } — selectionMode is "click" or "stroke",
// or "" when unset/invalid.
function parseConfig(raw) {
  var data
  try {
    data = JSON.parse(stripJsonc(raw))
  } catch (e) {
    return { items: [], error: String(e), selectionMode: "" }
  }
  var root = null
  var selectionMode = ""
  if (Array.isArray(data)) root = data
  else if (data && Array.isArray(data.items)) root = data.items
  else if (data && Array.isArray(data.children)) root = data.children
  if (!root) return { items: [], error: "expected an array of items, or { \"items\": [...] }", selectionMode: "" }
  if (data && !Array.isArray(data) && typeof data.selectionMode === "string") {
    var mode = data.selectionMode.toLowerCase()
    if (mode === "click" || mode === "stroke") selectionMode = mode
  }

  var items = []
  for (var i = 0; i < root.length; i++) {
    var item = normalizeItem(root[i], i)
    if (item) items.push(item)
  }
  if (items.length === 0) return { items: [], error: "no usable items found (need \"command\" or \"children\")", selectionMode: selectionMode }
  return { items: items, error: "", selectionMode: selectionMode }
}

// Serialize the editor's working tree back to a config document. Only
// writes fields the editor owns; user comments in the file are lost on
// save (documented in the README).
function serializeConfig(settings, items) {
  var out = {
    selectionMode: settings.selectionMode === "stroke" ? "stroke" : "click",
    items: []
  }
  for (var i = 0; i < items.length; i++) out.items.push(serializeItem(items[i]))
  return JSON.stringify(out, null, 2) + "\n"
}

function serializeItem(item) {
  var node = { name: item.name, icon: item.icon || "" }
  // Sub-wheel when it has children or was authored as a wheel without a
  // command; otherwise it's a command leaf.
  if (Array.isArray(item.children) && (item.children.length > 0 || !item.command)) {
    node.children = []
    for (var i = 0; i < item.children.length; i++)
      node.children.push(serializeItem(item.children[i]))
    if (item.command) node.command = item.command
  } else {
    node.command = item.command || "true"
  }
  return node
}

// Wheel shown before the user creates ~/.config/omarchy/extensions/omas.jsonc.
// Mirrors the sample config shipped in the repo.
function demoWheel() {
  return {
    title: "Omas demo",
    items: [
      {
        name: "Web", icon: "🌐",
        children: [
          { name: "Firefox", icon: "🦊", command: "firefox", children: [] },
          { name: "Private window", icon: "🕵️", command: "firefox --private-window", children: [] }
        ]
      },
      {
        name: "System", icon: "⚙️",
        children: [
          { name: "Lock", icon: "🔒", command: "omarchy system lock", children: [] },
          {
            name: "Power", icon: "⏻",
            children: [
              { name: "Reboot", icon: "🔄", command: "systemctl reboot", children: [] },
              { name: "Shutdown", icon: "⏹️", command: "systemctl poweroff", children: [] }
            ]
          }
        ]
      },
      { name: "Terminal", icon: "💻", command: "alacritty", children: [] },
      { name: "Screenshot", icon: "📸", command: "omarchy capture screenshot", children: [] },
      { name: "Files", icon: "📁", command: "xdg-open ~", children: [] }
    ]
  }
}
