# omarchy-plugins

My custom [Omarchy](https://omarchy.org) plugins and configuration.

| Repo path     | Install location             | Contents |
|---------------|------------------------------|----------|
| `plugins/`    | `~/.config/omarchy/plugins/` | Custom Omarchy shell (Quickshell) plugins |
| `omarchy/`    | `~/.config/omarchy/`         | Shell settings, menu extension, hooks, themes, branding |
| `hypr/`       | `~/.config/hypr/`            | Hyprland (Lua) config and display profiles |
| `bin/`        | `~/.local/bin/`              | Helper scripts used by the config and plugins |
| `quickshell/` | `~/.config/quickshell/`      | Remmina launcher |
| `install.sh`  | n/a                          | Interactive installer (see [Installing](#installing)) |

Not included: third-party plugins (e.g. `jankeesvw.notification-center`, which has its own repo), wallpapers, `.bak` files and `plugins-archive/`.

## Plugins (`plugins/`)

| Plugin | Kind | Description |
|--------|------|-------------|
| `bw-vault` | bar widget (System) | Button that opens/closes the Bitwarden CLI vault window. Tracks the running state via a PID file in `$XDG_RUNTIME_DIR` and calls `bw-vault-toggle` / `bw-vault-exit`. |
| `yonathan.displays` | overlay | "Displays & Workspaces" manager. Arrange monitors, place and number workspaces, and switch display profiles automatically. Logic lives in `Logic.js` (with tests in `tests/`). Opened with `SUPER+SHIFT+N` or the `trigger.displays` menu entry. |
| `yonathan.monitor-profile` | bar widget (System) | Shows the active monitor/workspace profile (e.g. `desk`) in the bar. |
| `yonathan.tray` | bar widget (Status) | Custom system tray (status notifier items), cloned from `omarchy.tray`. |
| `yonathan.workspaces` | bar widget (Compositor) | Workspace indicators, cloned from `omarchy.workspaces`. `WorkspaceOrder.js` orders them according to `hypr/workspace-order.json` (tests in `tests/`). |
| `yonathan.workspace-backgrounds` | bar widget (Appearance) | Assign a background image to each workspace. The panel stores the mapping in a state file and applies it with `omarchy-theme-bg-set`; images are picked via `omarchy-theme-bg-switcher`. |
| `yonathan.workspace-launcher` | overlay (kept loaded) | Searchable launcher over open windows and applications; selecting one switches to its workspace. Opened with `SUPER+N`. |

## Omarchy settings (`omarchy/`)

- **`shell.toml`**: base font size (`12`).
- **`shell.json`**: Omarchy shell config.
  - `idle`: screensaver after 150 s, lock after 300 s.
  - `bar`: top position, opaque, centered on `omarchy.clock`.
    - Left: Omarchy menu, `yonathan.workspaces`, `yonathan.workspace-backgrounds`.
    - Center: keyboard layout, indicators, clock (`dddd HH:mm`, alt format `d MMMM 'W'ww yyyy`), weather, system update.
    - Right: `yonathan.monitor-profile`, `yonathan.tray`, `bw-vault`, notification center, tailscale, agents, bluetooth, network, monitor, audio, power.
  - `plugins`: loaded plugins (`yonathan.displays`, `yonathan.workspace-launcher`, `bw-vault`).
- **`extensions/omarchy-menu.jsonc`**: adds to the Omarchy menu (`omarchy menu summon <name>`):
  - `trigger.displays`: open Displays & Workspaces.
  - `trigger.monitor-profile.*`: apply a display profile (`omarchy-display-profiles apply <name>`).
  - `trigger.workspaces.*`: switch to a named workspace (`omarchy-workspace-switch`).
  - `trigger.move-window-workspace.*`: move the focused window to a named workspace or the scratchpad (`omarchy-workspace-move-window`).
- **`hooks/`**: Omarchy hooks. `theme-set` runs `omazed set <theme>` so Zed follows the theme. The `post-update.d/*.hook` files invite you (once) to install Voxtype dictation, pick a default agent and set up the fingerprint reader. `*.sample` files are the stock examples.
- **`themes/`**, **`themed/`**: theme color/icon files and a sample template.
- **`branding/`**: `about.txt` and `screensaver.txt`.

## Hyprland (`hypr/`)

- **`hyprland.lua`**: entry point. Loads the Omarchy defaults, then `monitors`, `input`, `bindings`, `looknfeel`, `autostart`, and the generated `workspace-profile.lua`.
- **`monitors.lua`**: default monitor rule (preferred mode, auto position, scale 1) plus an `omarchy-display-profiles`-managed block for the internal panel (`eDP-1`).
- **`input.lua`**, **`looknfeel.lua`**: personal override files; currently only commented examples (Omarchy defaults apply).
- **`bindings.lua`**: custom keybindings.

  | Key | Action |
  |-----|--------|
  | `SUPER+B` | Toggle Bitwarden vault (`bw-vault-toggle`) |
  | `ALT+SPACE`, `SUPER+M` | Workspace switcher menu |
  | `SUPER+SHIFT+M` | Move window to workspace menu (replaces Spotify) |
  | `SUPER+N` | Workspace launcher plugin |
  | `SUPER+SHIFT+N` | Displays & Workspaces manager |
  | `SUPER+SHIFT+ALT+arrows` | Move window to the workspace on the monitor in that direction |
  | `SUPER+R` | Remmina launcher (`~/.config/quickshell/remmina-launcher/toggle.sh`) |
- **`autostart.lua`**: starts `omarchy-display-profiles watch` (auto-switch profile on monitor changes), launches the daily apps (opencode, Zen, Zed, Remmina, Slack, Chromium web apps) and uses window rules to place each on its workspace. Also points `SSH_AUTH_SOCK` at the systemd user `ssh-agent.socket`.
- **`workspace-profile.lua`**: *generated* by `omarchy-display-profiles` for the active profile. Don't edit by hand; use the Displays & Workspaces manager.
- **`workspace-order.json`**: generated workspace order and workspace-to-monitor assignments for the active profile.
- **`display-profiles/`**
  - `catalog.json`: workspace catalog (name, number, app class patterns, launch commands).
  - `profiles/*.json`: monitor layouts, matched by make/model/serial: `desk`, `laptop`, `office`, `office-4k`, `office-corner`, `andere-office`, `new-profile`.
- **`hyprsunset.conf`**: identity profile, so hyprsunset doesn't tint the screen by default (night light is opt-in).
- **`xdph.conf`**: xdg-desktop-portal-hyprland screencopy: allow tokens by default and use `hyprland-preview-share-picker`.
- **`.luarc.json`**: Lua language server config.

## Scripts (`bin/`, `quickshell/`)

| Path | Install location | Description |
|------|------------------|-------------|
| `bin/bw-vault-toggle`, `bin/bw-vault-exit` | `~/.local/bin/` | Open/close the Bitwarden vault window; exit locks the vault. |
| `bin/omarchy-display-profiles` | `~/.local/bin/` | Applies/watches display profiles and generates `workspace-profile.lua`. |
| `bin/omarchy-workspace-switch`, `bin/omarchy-workspace-move-window` | `~/.local/bin/` | Switch to / move a window to a named workspace. |
| `bin/wait-for-notifications` | `~/.local/bin/` | Waits for the notification service before launching an app (used in autostart). |
| `quickshell/remmina-launcher/` | `~/.config/quickshell/` | Remmina launcher popup (`SUPER+R`). |

## External dependencies

Not stored here: `omazed` (used by the `theme-set` hook; not currently installed on this machine) and the Omarchy-provided `omarchy-*` commands.

## Installing

```sh
git clone git@github.com:ybensoussan/omarchy-plugins.git
cd omarchy-plugins
./install.sh
```

`install.sh` shows a picker (uses [`gum`](https://github.com/charmbracelet/gum), which ships with Omarchy; falls back to a numbered prompt) where you choose what to install:

- each plugin individually (`plugins/*` -> `~/.config/omarchy/plugins/`)
- Omarchy shell settings (`shell.json`, `shell.toml`)
- Omarchy menu extension
- Omarchy hooks
- Omarchy themes, templates and branding
- Hyprland config (`hypr/` -> `~/.config/hypr/`)
- helper scripts (`bin/` -> `~/.local/bin/`)
- Remmina launcher (`quickshell/` -> `~/.config/quickshell/`)

Options:

| Flag | Effect |
|------|--------|
| `--all` | Install everything without prompting |
| `--link` | Symlink instead of copy, so edits in `~/.config` go straight into the repo (handy for committing changes) |
| `--dry-run` | Print what would be done without changing anything |

Anything that already exists is moved aside as `<name>.bak.<timestamp>` before being replaced, and already-correct symlinks are left alone.

After installing, apply the changes:

```sh
hyprctl reload
omarchy-restart-shell
```

Notes:
- `shell.json` enables plugins by id. Selecting only some plugins means the matching bar entries in `shell.json` will refer to plugins that aren't installed, so install the shell settings together with the plugins they list.
- `hypr/workspace-profile.lua`, `workspace-order.json` and the monitor profiles in `display-profiles/` are specific to my monitors (matched by make/model/serial). On other hardware, install the config and then recreate profiles with the Displays & Workspaces manager (`SUPER+SHIFT+N`).
- `omazed` (used by the `theme-set` hook) must be installed separately.
