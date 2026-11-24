#!/usr/bin/env bash
# Uninstalls TIDAL Player: disables and removes the plugin (the widget), stops
# the daemon and removes its systemd unit, and deletes the session, playback
# state and runtime files. The shell owns this because it removes the widget —
# the CLI is a daemon client and never touches the plugin. It runs through
# `omarchy shell tidalplayer uninstall`, which opens a floating terminal so the
# confirmation prompt has a real TTY. `--yes` skips the prompt.
set -u

PLUGIN_ID="scorchedegg.tidalplayer"
SERVICE_NAME="omarchy-tidalplayer.service"
LEGACY_SERVICES=("omarchy-tidalplayerd.service" "omarchy-tidald.service")
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname -- "$SCRIPT_DIR")"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}"

if [[ "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
  if [[ ! -t 0 ]]; then
    echo "refusing to uninstall without confirmation; pass --yes for a non-interactive run" >&2
    exit 1
  fi
  echo "This will:"
  echo "  - disable and remove the TIDAL Player plugin"
  echo "  - stop the daemon and remove its systemd unit"
  echo "  - delete your TIDAL session, queue, playhead, artwork and runtime files"
  read -r -p "Continue? [y/N] " answer
  case "${answer,,}" in
    y | yes) ;;
    *)
      echo "Uninstall cancelled."
      exit 0
      ;;
  esac
fi

# Stop and remove the unit, its wants link and drop-ins (plus the legacy
# names from earlier builds).
for unit in "$SERVICE_NAME" "${LEGACY_SERVICES[@]}"; do
  systemctl --user disable "$unit" >/dev/null 2>&1
  systemctl --user stop "$unit" >/dev/null 2>&1
  rm -f "$UNIT_DIR/$unit" "$UNIT_DIR/default.target.wants/$unit"
  rm -rf "$UNIT_DIR/$unit.d"
done
systemctl --user daemon-reload >/dev/null 2>&1
for unit in "$SERVICE_NAME" "${LEGACY_SERVICES[@]}"; do
  systemctl --user reset-failed "$unit" >/dev/null 2>&1
done
echo "Removed the systemd unit."

# Delete the session, playback state and runtime files (plus the legacy names
# and top-level runtime files older builds left behind).
rm -rf "$STATE_BASE/scorchedegg.tidalplayer" "$STATE_BASE/omarchy-tidal"
if [[ -d "$RUNTIME_DIR" ]]; then
  rm -rf "$RUNTIME_DIR/scorchedegg.tidalplayer"
  for entry in "$RUNTIME_DIR"/omarchy-tidalplayer* "$RUNTIME_DIR"/omarchy-tidal-*; do
    [[ -e "$entry" || -L "$entry" ]] && rm -rf "$entry"
  done
fi
rm -f /tmp/omarchy-tidalplayer.log /tmp/omarchy-tidalplayerd.log
echo "Cleared the TIDAL session, queue, playback state and runtime files."

# Disable, then remove, the plugin.
if omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 ||
  omarchy-shell shell setPluginEnabled "$PLUGIN_ID" false >/dev/null 2>&1; then
  echo "Disabled the plugin."
else
  echo "The plugin was already disabled or could not be disabled; continuing."
fi

if omarchy plugin remove "$PLUGIN_ID" --yes >/dev/null 2>&1; then
  echo "Removed the plugin."
elif [[ "$(basename -- "$PLUGIN_DIR")" == "$PLUGIN_ID" ]]; then
  # Fallback for a shell without the plugin CLI. Only touch a path whose
  # final component is this plugin's id.
  rm -rf "$PLUGIN_DIR"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1
  echo "Removed the plugin directory."
else
  echo "The plugin directory could not be removed automatically."
fi

echo "TIDAL Player has been uninstalled."
