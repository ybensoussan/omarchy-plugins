-- Keep only your personal keybinding overrides here. Add new bindings or
-- unbind defaults before replacing them.

-- See current bindings and descriptions:
--   omarchy menu keybindings --print

-- To disable every Omarchy default binding, set this in
-- ~/.config/hypr/hyprland.lua before require("default.hypr.omarchy"), then add
-- only the bindings you want below:
--   omarchy_default_bindings = false

-- To disable all preinstalled app/webapp bindings, set:
--   omarchy_preinstalled_bindings = false

-- Add a new binding.
-- o.bind("SUPER + R", "SSH", "alacritty -e ssh your-server")

o.bind("SUPER + B", "Bitwarden vault", "bw-vault-toggle")

-- Change an existing binding by unbinding it first, then binding the key again.
-- This example changes SUPER+SPACE from the launcher to the Omarchy root menu.
-- hl.unbind("SUPER + SPACE")
-- o.bind("SUPER + SPACE", "Omarchy menu", "omarchy-menu toggle root")

-- Disable a default binding without replacing it.
-- hl.unbind("SUPER + SHIFT + B")

-- Workspace switcher
o.bind("ALT + SPACE", "Workspace switcher", "omarchy menu summon workspace")
o.bind("SUPER + M", "Workspace switcher", "omarchy menu summon workspace")
-- Replace the default Spotify launcher with the workspace mover.
hl.unbind("SUPER + SHIFT + M")
hl.unbind("SUPER + CTRL + M")
o.bind("SUPER + SHIFT + M", "Move window to workspace", "omarchy menu summon move-window-workspace")

hl.unbind("SUPER + N")
o.bind("SUPER + N", "Workspace launcher", function()
  hl.exec_cmd("omarchy-shell -q yonathan.workspace-launcher show")
end)
-- Override Omarchy's editor launcher on this shortcut.
hl.unbind("SUPER + SHIFT + N")
o.bind("SUPER + SHIFT + N", "Display & workspace manager", "omarchy-shell shell toggle yonathan.displays ''")

-- Move the focused window to the workspace shown on an adjacent monitor.
for key, direction in pairs({ LEFT = "l", RIGHT = "r", UP = "u", DOWN = "d" }) do
  hl.unbind("SUPER + SHIFT + ALT + " .. key)
  o.bind("SUPER + SHIFT + ALT + " .. key, "Move window to " .. key:lower() .. " monitor", function()
    local workspace = hl.get_active_workspace(direction)
    if workspace then
      hl.dispatch(hl.dsp.window.move({ workspace = workspace.name }))
    end
  end)
end

-- Searchable Remmina connection launcher (~/.config/omarchy/plugins/yonathan.remmina-launcher).
hl.unbind("SUPER + R")
o.bind("SUPER + R", "Remmina launcher", function()
  hl.exec_cmd("omarchy-shell -q yonathan.remmina-launcher toggle")
end)
