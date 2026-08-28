# Omas

Too many keybindings? Use your mouse!

**Omas** is a radial
menu for [Omarchy](https://omarchy.org), built as a native Quickshell shell
plugin. Your first wheel holds categories; each category opens a nested
wheel of commands — and the tree grows exactly as deep as you want. Point
at an item and click — that's all there is to it.

![Omas wheel](preview.png)

## Features

- **Custom command wheels** — categories, sub-wheels, commands; as many
  items and levels as you like (defined in one JSONC file, hot-reloaded on
  save)
- **Opens under your cursor** — the wheel is summoned right where the
  mouse is (sliding in from the edge when there's no room; falls back to
  the screen center if the cursor position can't be read)
- **Custom icons** — emoji, text glyphs, or image files (a starter icon
  pack ships with the plugin)
- **Built-in editor** — open it right from the wheel's center; add, edit,
  and delete wheels and commands, nest sub-wheels with their items inline,
  and save straight to the config file
- **Native Omarchy integration** — runs inside the omarchy-shell process,
  themed by your Omarchy style, summoned through the standard shell IPC

## Requirements

- [Omarchy](https://omarchy.org) with its Quickshell shell (the default)
- Hyprland (the shell IPC and keybind live there)
- `python3` (used to read the config through a size-capped, no-symlink
  file descriptor; standard on Omarchy systems)

## Installation

The default Omarchy way — install straight from git:

```bash
omarchy plugin add https://github.com/Palccod/Omas.git --enable
```

That clones the plugin into `~/.config/omarchy/plugins/palccod.omas/`,
enables it, and asks the shell to pick it up. A sample wheel config is
created at `~/.config/omarchy/extensions/omas.jsonc` on first launch.

For development, clone the repo into
`~/.config/omarchy/plugins/palccod.omas/` yourself, enable it with
`omarchy plugin enable palccod.omas`, and run
`omarchy-shell shell rescanPlugins` (or `omarchy restart shell`) after
editing files.

## Keybind — SUPER + Z

Omas is summoned through the shell IPC. The default keybind this plugin is
designed for is **SUPER + Z**; it's free in a stock Omarchy setup, so add
it to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + Z", "Omas wheel", "omarchy-shell shell toggle palccod.omas")
```

The command toggles the wheel — press once to open, once more to dismiss.
Of course you can use any key you like. If your key of choice is already
bound by Omarchy defaults, unbind it first, then bind it to Omas:

```lua
hl.unbind("SUPER + Z")                       -- only if it's already taken
o.bind("SUPER + Z", "Omas wheel", "omarchy-shell shell toggle palccod.omas")
```

(See every current binding with `omarchy menu keybindings --print`.)

Handy IPC variants:

```bash
omarchy-shell shell summon palccod.omas               # open the wheel
omarchy-shell shell summon palccod.omas '{"edit":true}'       # open the editor
omarchy-shell shell hide palccod.omas                 # dismiss
```

## Usage — the user flow

1. Press **SUPER + Z** — the wheel opens right under your cursor.
2. Point at a category (Web, System, …) and click — its sub-wheel opens.
   The center circle always takes you **back** one level.
3. Point at a command and click — it runs and the wheel closes.
4. At the root wheel, the center circle says **settings**: click it to
   open the wheel editor.

### The editor

- **Browse** — the root list of your wheel; `›` drills into a sub-wheel,
  `✎` edits, `✕` deletes (with confirmation)
- **Add item** — name, icon, and either a command or the **Sub-wheel**
  toggle. Toggling Sub-wheel reveals the items *inside* it — the same
  list + **+ Add item** UI as the main page — so you build nested wheels
  without ever leaving the form, as deep as you like
- **Cancel** steps back one level (form → list → back to the wheel); it
  never closes the menu. **Save & close** writes the config file and
  applies it immediately — the live wheel updates on the spot

Escape follows the same logic: it cancels a dialog, a form, or the editor
— only at the root wheel does it dismiss the menu.

## Configuration

Everything lives in `~/.config/omarchy/extensions/omas.jsonc` (JSONC —
comments and trailing commas allowed). Edits apply live; the editor writes
this file too.

```jsonc
{
  "items": [
    {
      "name": "Web",
      "icon": "🌐",                   // emoji, glyph, or "/path/to/image.png"
      "children": [
        { "name": "Chromium", "icon": "🌐", "command": "chromium" },
        { "name": "Private window", "icon": "🕵️", "command": "chromium --incognito" }
      ]
    },
    { "name": "Terminal", "icon": "💻", "command": "foot" }
  ]
}
```

- A node with `children` opens a sub-wheel; a node with a `command` runs
  it through bash.
- **Sizes are bounded** to protect the long-lived shell: the config file
  is capped at 256 KiB, 200 total items, 8 nesting levels, and per-field
  lengths (name 64, icon/path 256, command 1024 characters). An
  over-limit file is rejected whole — Omas keeps showing the last good
  wheel and says "Config error" in the center — and the editor refuses to
  save an over-limit tree.
- **Icons**: emoji and text glyphs render directly. For images, use an
  absolute path. The plugin ships a starter pack in its install dir —
  `web.png`, `firefox.png`, `private.png`, `system.png`, `lock.png`,
  `power.png`, `reboot.png`, `shutdown.png`, `terminal.png`,
  `screenshot.png`, `files.png`, `vscode.png` — e.g.
  `/home/YOU/.config/omarchy/plugins/palccod.omas/web.png`. Copy in your
  own PNGs and point items at them however you like.

Editor walkthrough: ![editor](assets/wheel-settings.png) ![adding
items](assets/add-item.png) ![sub-wheels](assets/add-sub-wheel.png)

## Update

```bash
omarchy plugin update palccod.omas
```

If the shell somehow keeps running old code after an update,
`omarchy restart shell`.

## Removal

```bash
omarchy plugin remove palccod.omas          # disables + deletes the plugin
```

Then remove your config (`~/.config/omarchy/extensions/omas.jsonc`) and
the keybind you added in `bindings.lua`.

## Security & privacy

- **No network access** — Omas never makes network requests
- **No privileged behavior** — no sudo, polkit, services, or system files
- **File access** — reads and writes only
  `~/.config/omarchy/extensions/omas.jsonc` (your own wheel definition).
  Reads are producer-bounded: the file is opened with `O_NOFOLLOW`,
  regular-file-checked, and read at most 256 KiB before anything reaches
  the UI; writes are atomic (temp file + rename) and size-capped. No
  other files are touched
- **Process execution** — runs exactly the shell commands you configure in
  your wheel, when you select them; nothing is executed automatically
- **No data collection** — nothing leaves your machine; there are no
  telemetry, clipboard, or credential reads

## Development notes

- QML sources: `Menu.qml` (wheel, IPC surface),
  `Editor.qml` (settings UI), `PieModel.js` (config parsing/serialization)
- Lint with `qmllint -I /usr/share/omarchy/shell *.qml`, validate with
  `omarchy plugin validate <folder>`
- `omarchy-shell shell call palccod.omas ping x` returns a JSON state
  dump — handy for checking which code the shell is actually running
- Roadmap ideas: item reordering/duplicate in the editor, per-item
  themes (sizes, wedge colors), hold-to-open / release-to-launch through
  a second keybind

## Credits

- Built on [Quickshell](https://quickshell.outfoxxed.me) and Omarchy's
  shell plugin API

## License

MIT
