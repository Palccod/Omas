#!/usr/bin/env bash
# Install Omas into the live Omarchy shell config.
#   ./setup/install.sh          copy files into ~/.config/omarchy/plugins
#   ./setup/install.sh --link   symlink the repo dir instead (dev mode)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ID="palccod.omas"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
CONFIG_DEST="$HOME/.config/omarchy/extensions/omas.jsonc"

mkdir -p "$HOME/.config/omarchy/plugins" "$HOME/.config/omarchy/extensions"

if [[ "${1:-}" == "--link" ]]; then
  rm -rf "$DEST"
  ln -s "$REPO_DIR" "$DEST"
  echo "Linked $DEST -> $REPO_DIR"
else
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp "$REPO_DIR/manifest.json" "$REPO_DIR/Menu.qml" "$REPO_DIR/Editor.qml" "$REPO_DIR/PieModel.js" "$DEST/"
  cp "$REPO_DIR/README.md" "$REPO_DIR/omas.jsonc" "$DEST/" 2>/dev/null || true
  echo "Copied plugin files to $DEST"
fi

if [[ ! -f "$CONFIG_DEST" ]]; then
  cp "$REPO_DIR/omas.jsonc" "$CONFIG_DEST"
  echo "Created sample config at $CONFIG_DEST"
fi

omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 \
  || echo "NOTE: enable it manually with: omarchy plugin enable $PLUGIN_ID"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo "Done. Try: omarchy-shell shell summon $PLUGIN_ID '{}'"
