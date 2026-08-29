// Omas wheel tree model: parse + validate the user's JSONC definition.
//
// The config is a tree of nodes. A node with "children" opens a sub-wheel;
// a node with "command" runs it through bash. "icon" is an emoji, a text
// glyph, or an absolute path to an image.
//
// Everything parsed or serialized is bounded by the budgets below: a
// grown or malformed config is rejected whole (the caller keeps the last
// good wheel) before the shell materializes repeaters, canvases, or image
// sources from it. Normalization is iterative — nesting depth never
// drives recursion.

.pragma library

var MAX_FILE_CHARS = 256 * 1024   // raw config document
var MAX_ITEMS = 200               // total items across all wheels
var MAX_DEPTH = 8                 // sub-wheel nesting levels
var MAX_NAME_CHARS = 64
var MAX_ICON_CHARS = 256          // also covers absolute image paths
var MAX_COMMAND_CHARS = 1024

function limitError(what) {
  return "config exceeds limits (" + what + "); keeping the last good wheel"
}

function stripJsonc(raw) {
  return String(raw || "")
    .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
    .replace(/,(\s*[}\]])/g, "$1")
}

// Parse a full config document. Accepts either a top-level array or an
// object with an "items" (or "children") array. Returns { items, error,
// mode }, where mode is the optional summon mode ("click", the default,
// or "hold"). Unknown keys (including the removed "selectionMode") are
// ignored. A node with an explicit (possibly empty) "children" array is
// kept as an empty sub-wheel — the editor relies on this so new wheels
// survive a save/reload round-trip before their first child is added.
function parseConfig(raw) {
  if (String(raw || "").length > MAX_FILE_CHARS)
    return { items: [], error: limitError("over " + MAX_FILE_CHARS + " characters"), mode: "click" }

  var data
  try {
    data = JSON.parse(stripJsonc(raw))
  } catch (e) {
    return { items: [], error: String(e), mode: "click" }
  }

  var root = null
  if (Array.isArray(data)) root = data
  else if (data && Array.isArray(data.items)) root = data.items
  else if (data && Array.isArray(data.children)) root = data.children
  if (!root)
    return { items: [], error: "expected an array of items, or { \"items\": [...] }", mode: "click" }
  var mode = data && !Array.isArray(data) && data.mode === "hold" ? "hold" : "click"

  var items = []
  var count = 0
  var stack = [{ src: root, out: items, depth: 0 }]
  while (stack.length > 0) {
    var frame = stack.pop()
    for (var i = 0; i < frame.src.length; i++) {
      var value = frame.src[i]
      if (!value || typeof value !== "object") continue
      var hadChildren = Array.isArray(value.children)
      var command = typeof value.command === "string" ? value.command
        : (typeof value.action === "string" ? value.action : "")
      if (!command && !hadChildren) continue
      var name = String(value.name || value.label || ("Item " + (i + 1)))
      var icon = String(value.icon || "")
      if (name.length > MAX_NAME_CHARS)
        return { items: [], error: limitError("item name over " + MAX_NAME_CHARS + " characters") }
      if (icon.length > MAX_ICON_CHARS)
        return { items: [], error: limitError("icon over " + MAX_ICON_CHARS + " characters") }
      if (command.length > MAX_COMMAND_CHARS)
        return { items: [], error: limitError("command over " + MAX_COMMAND_CHARS + " characters") }
      if (++count > MAX_ITEMS)
        return { items: [], error: limitError("more than " + MAX_ITEMS + " items") }
      var item = { name: name, icon: icon, command: command, children: [] }
      if (hadChildren) {
        if (frame.depth + 1 > MAX_DEPTH)
          return { items: [], error: limitError("nesting deeper than " + MAX_DEPTH + " levels") }
        stack.push({ src: value.children, out: item.children, depth: frame.depth + 1 })
      }
      frame.out.push(item)
    }
  }

  if (items.length === 0)
    return { items: [], error: "no usable items found (need \"command\" or \"children\")", mode: mode }
  return { items: items, error: "", mode: mode }
}

// True when a (possibly editor-grown) tree fits every budget.
function withinBudgets(items) {
  var count = 0
  var stack = [{ items: items, depth: 0 }]
  while (stack.length > 0) {
    var frame = stack.pop()
    for (var i = 0; i < frame.items.length; i++) {
      var item = frame.items[i]
      if (!item) continue
      if (++count > MAX_ITEMS) return false
      if (String(item.name || "").length > MAX_NAME_CHARS) return false
      if (String(item.icon || "").length > MAX_ICON_CHARS) return false
      if (String(item.command || "").length > MAX_COMMAND_CHARS) return false
      if (Array.isArray(item.children) && item.children.length > 0) {
        if (frame.depth + 1 > MAX_DEPTH) return false
        stack.push({ items: item.children, depth: frame.depth + 1 })
      }
    }
  }
  return true
}

// Serialize the editor's working tree back to a config document. Returns
// "" when the tree exceeds any budget (the caller must not write it).
// Only writes fields the editor owns; user comments in the file are lost
// on save (documented in the README).
function serializeConfig(items) {
  if (!withinBudgets(items)) return ""
  var out = { items: [] }
  for (var i = 0; i < items.length; i++) out.items.push(serializeItem(items[i]))
  var json = JSON.stringify(out, null, 2) + "\n"
  return json.length <= MAX_FILE_CHARS ? json : ""
}

function serializeItem(item) {
  var node = { name: item.name, icon: item.icon || "" }
  // Sub-wheel when it has children or was authored as a wheel without a
  // command; otherwise it's a command leaf. Recursion depth is bounded:
  // serializeConfig only runs on trees that passed withinBudgets().
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
          { name: "Firefox", icon: "🌐", command: "chromium", children: [] },
          { name: "Private window", icon: "🕵️", command: "chromium --incognito", children: [] }
        ]
      },
      {
        name: "System", icon: "⚙️",
        children: [
          { name: "Lock", icon: "🔒", command: "omarchy system lock", children: [] },
          { name: "Sleep", icon: "🌙", command: "systemctl sleep", children: [] },
          {
            name: "Power", icon: "⏻",
            children: [
              { name: "Reboot", icon: "🔄", command: "systemctl reboot", children: [] },
              { name: "Shutdown", icon: "⏹️", command: "systemctl poweroff", children: [] }
            ]
          }
        ]
      },
      { name: "Terminal", icon: "💻", command: "foot", children: [] },
      { name: "Screenshot", icon: "📸", command: "omarchy capture screenshot", children: [] },
      { name: "Files", icon: "📁", command: "xdg-open ~", children: [] },
      { name: "Editor", icon: "📝", command: "foot nvim", children: [] }
    ]
  }
}
