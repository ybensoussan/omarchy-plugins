# AGENTS.md

Guidance for AI agents working in this repo. See `README.md` for the human-facing overview and per-plugin/per-setting descriptions.

## What this repo is

A backup of one user's (yonathan) custom [Omarchy](https://omarchy.org) setup: Quickshell shell plugins, Omarchy shell config, Hyprland Lua config, and helper scripts. It is a **mirror of files that live under `$HOME`**, not an app with a build. There is no build step; the only tests are the plugin unit tests (see below).

The live copies are the source of truth for day-to-day use. The repo holds copies (or symlinks, if installed with `--link`).

## Layout and where each path lives on the machine

| Repo path | Live location | Notes |
|-----------|---------------|-------|
| `plugins/<id>/` | `~/.config/omarchy/plugins/<id>/` | QML/JS plugins, each with a `manifest.json` |
| `omarchy/shell.json`, `omarchy/shell.toml` | `~/.config/omarchy/` | Bar layout, idle timers, enabled plugins, font size |
| `omarchy/extensions/omarchy-menu.jsonc` | `~/.config/omarchy/extensions/` | Adds entries to the Omarchy menu |
| `omarchy/hooks/` | `~/.config/omarchy/hooks/` | `*.sample` files are stock examples; real hooks have no `.sample` suffix |
| `omarchy/themes/`, `themed/`, `branding/` | `~/.config/omarchy/` | |
| `hypr/` | `~/.config/hypr/` | Hyprland **Lua** config (`hyprland.lua` is the entry point) |
| `bin/` | `~/.local/bin/` | Helper scripts invoked by keybindings, menu entries, plugins |
| `quickshell/remmina-launcher/` | `~/.config/quickshell/remmina-launcher/` | Standalone Quickshell popup |
| `install.sh` | n/a | Interactive installer (`--all`, `--link`, `--dry-run`) |

## Plugins

Each plugin dir has a `manifest.json` (`schemaVersion`, `id`, `kinds`, `entryPoints`, optional `barWidget` block). `id` must match the directory name and the id used in `omarchy/shell.json`. Kinds are `bar-widget` or `overlay`.

Plugins: `bw-vault`, `yonathan.displays` (overlay, the Displays & Workspaces manager), `yonathan.monitor-profile`, `yonathan.tray` and `yonathan.workspaces` (clones of the stock `omarchy.tray` / `omarchy.workspaces`), `yonathan.workspace-backgrounds`, `yonathan.workspace-launcher` (overlay). `yonathan.bw-vault` is a stale duplicate directory with only a manifest-less stub; prefer `bw-vault`.

Tests (plain Node, no deps):
```sh
node plugins/yonathan.displays/tests/logic.test.mjs
node plugins/yonathan.workspaces/tests/order.test.cjs
```

## How the pieces connect

- `hypr/bindings.lua` binds keys to `bin/*` scripts, `omarchy menu summon ...`, and `omarchy-shell ... yonathan.<plugin> ...`.
- `omarchy/extensions/omarchy-menu.jsonc` entries call `omarchy-display-profiles`, `omarchy-workspace-switch`, `omarchy-workspace-move-window`.
- `hypr/autostart.lua` runs `omarchy-display-profiles watch`, which regenerates `hypr/workspace-profile.lua` and `hypr/workspace-order.json` when monitors change.
- Workspace names/numbers come from `hypr/display-profiles/catalog.json`; monitor layouts from `hypr/display-profiles/profiles/*.json`.

## Rules and gotchas

- **Generated files: do not hand-edit** `hypr/workspace-profile.lua`, `hypr/workspace-order.json`, and the marked block in `hypr/monitors.lua` (`>>> omarchy-display-profiles ... <<<`). Change profiles via the manager plugin or `omarchy-display-profiles`, then re-sync.
- **Hardware-specific:** profiles match monitors by make/model/serial and workspace rules use output names (`eDP-1`, `DP-4`, `DP-5`). Do not "fix" them for other hardware without being asked.
- **Absolute paths:** some configs hardcode `/home/yonathan/...` (e.g. `hypr/autostart.lua`, `hypr/bindings.lua`). Keep them unless asked to generalize.
- **Don't commit:** `*.bak*` files, `plugins-archive/`, wallpapers/`backgrounds/`, third-party plugins (e.g. `jankeesvw.notification-center`, which has its own repo), the factory theme's images, or anything secret. Before committing, grep for `password|secret|token|api[_-]?key`.
- **`hypr/*.lua` is Lua, not hyprlang.** Uses the Omarchy `o.*` helpers (`o.bind`, `o.window`, `o.launch_on_start`) and `hl.*` APIs.
- `shell.json` lists plugins by id; if you add/remove a plugin, update both `plugins/` and `shell.json` (bar `layout` and the `plugins` array), and the README plugin table.
- Keep `README.md` in sync when adding plugins, scripts, keybindings, or menu entries.

## Syncing live config into the repo

The repo is updated by copying from the live locations (excluding backups):

```sh
R=~/omarchy-plugins; C=~/.config
for p in $R/plugins/*/; do n=$(basename $p); [ -d $C/omarchy/plugins/$n ] && rsync -a --delete --exclude='*.bak*' $C/omarchy/plugins/$n/ $p; done
rsync -a --exclude='*.bak*' $C/hypr/ $R/hypr/
rsync -a --exclude='*.bak*' $C/omarchy/{shell.json,shell.toml,extensions,hooks,branding,themed} $R/omarchy/
for s in $R/bin/*; do cp -a ~/.local/bin/$(basename $s) $s; done
rsync -a --exclude='*.bak*' $C/quickshell/remmina-launcher/ $R/quickshell/remmina-launcher/
git -C $R status --short   # review the diff before committing
```

If installed with `./install.sh --link`, live files are symlinks into the repo, so no sync is needed.

## Git

- Remote: `git@github.com:ybensoussan/omarchy-plugins.git`, branch `main`.
- `main` has a branch-protection notice ("Changes must be made through a pull request") but pushes by the owner have succeeded. If a push is rejected, push a branch and open a PR with `gh`.
- Small, descriptive commits; don't force-push.

## Testing changes

- Shell scripts: `bash -n script` (or `sh -n`); `./install.sh --dry-run` to check installer behavior.
- Config/plugins can only be fully verified on the live desktop: `hyprctl reload` for Hyprland, `omarchy-restart-shell` for the shell/plugins. Ask the user before restarting their shell or reloading their session.
