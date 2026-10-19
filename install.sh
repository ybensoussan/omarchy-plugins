#!/usr/bin/env bash
# Interactive installer: pick which parts of this repo to copy into $HOME.
# Usage: ./install.sh [--all] [--link] [--dry-run]
#   --all      install everything without prompting
#   --link     symlink instead of copy (edits in ~/.config flow back to the repo)
#   --dry-run  print what would happen
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
BIN="$HOME/.local/bin"
STAMP="$(date +%Y%m%d-%H%M%S)"
ALL=0 LINK=0 DRY=0
for a in "$@"; do
  case $a in
    --all) ALL=1 ;; --link) LINK=1 ;; --dry-run) DRY=1 ;;
    -h|--help) sed -n 2,6p "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option: $a" >&2; exit 1 ;;
  esac
done

# label|source (relative to repo)|destination
ITEMS=()
for p in "$REPO"/plugins/*/; do
  n=$(basename "$p")
  ITEMS+=("Plugin: $n|plugins/$n|$CFG/omarchy/plugins")
done
ITEMS+=(
  "Omarchy shell settings (shell.json, shell.toml)|omarchy/shell.json omarchy/shell.toml|$CFG/omarchy"
  "Omarchy menu extension|omarchy/extensions|$CFG/omarchy"
  "Omarchy hooks|omarchy/hooks|$CFG/omarchy"
  "Omarchy themes, themed templates and branding|omarchy/themes omarchy/themed omarchy/branding|$CFG/omarchy"
  "Hyprland config (hypr/*.lua, conf, json)|hypr/.|$CFG/hypr"
  "Helper scripts (bin/ -> ~/.local/bin)|bin/.|$BIN"
  "Remmina launcher (quickshell)|quickshell/remmina-launcher|$CFG/quickshell"
)

labels=(); for i in "${ITEMS[@]}"; do labels+=("${i%%|*}"); done

if (( ALL )); then
  chosen=("${labels[@]}")
elif command -v gum >/dev/null; then
  mapfile -t chosen < <(gum choose --no-limit --height 20 \
    --header "Select what to install (space = toggle, enter = confirm)" "${labels[@]}")
else
  echo "Select what to install (numbers separated by spaces, 'a' for all):"
  for n in "${!labels[@]}"; do printf '  %2d) %s\n' $((n+1)) "${labels[$n]}"; done
  read -rp "> " reply
  chosen=()
  if [[ $reply == a ]]; then chosen=("${labels[@]}")
  else for n in $reply; do [[ -n ${labels[$((n-1))]:-} ]] && chosen+=("${labels[$((n-1))]}"); done; fi
fi

(( ${#chosen[@]} )) || { echo "Nothing selected."; exit 0; }

run() { if (( DRY )); then echo "+ $*"; else "$@"; fi; }

install_one() {
  local srcs=$1 dest=$2 s src target
  run mkdir -p "$dest"
  for s in $srcs; do
    src="$REPO/$s"
    if [[ $s == */. ]]; then   # directory contents -> dest
      for f in "$src"/* "$src"/.[!.]*; do [[ -e $f ]] && put "$f" "$dest/$(basename "$f")"; done
    else
      put "$src" "$dest/$(basename "$src")"
    fi
  done
}

put() {
  local src=$1 target=$2
  if [[ -e $target || -L $target ]]; then
    if [[ -L $target && $(readlink -f "$target") == "$(readlink -f "$src")" ]]; then return; fi
    run mv "$target" "$target.bak.$STAMP"
  fi
  if (( LINK )); then run ln -s "$src" "$target"; else run cp -a "$src" "$target"; fi
  echo "  installed $target"
}

for label in "${chosen[@]}"; do
  for i in "${ITEMS[@]}"; do
    [[ ${i%%|*} == "$label" ]] || continue
    rest=${i#*|}
    echo "==> $label"
    install_one "${rest%%|*}" "${rest#*|}"
  done
done

echo
echo "Done. Existing files were backed up as *.bak.$STAMP."
echo "Reload Hyprland (hyprctl reload) and restart the shell (omarchy-restart-shell) to apply."
