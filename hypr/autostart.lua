-- Extra autostart processes.
-- o.launch_on_start("my-service")
o.launch_on_start("omarchy-display-profiles watch")

-- Restore the applications currently used on each named workspace.
-- Window rules assign each app to its workspace by class; launches are plain
-- (the "[workspace N silent]" dispatch prefix isn't supported by this
-- Lua-based Hyprland parser / uwsm-app).
o.window("org.omarchy.agent",   { workspace = "1 silent" })
o.window("zen",                 { workspace = "2 silent" })
o.window("dev.zed.Zed",         { workspace = "3 silent" })
o.window("org.remmina.Remmina", { workspace = "4 silent" })
o.window("chrome-app.slack.com__client-Default", { workspace = "5 silent" })
o.window("ai.opencode.desktop", { workspace = "7 silent" })
o.window("chrome-faolnafnngnfdaknnbpnkhgohbobgegn-Default", { workspace = "8 silent" })
o.window("chrome-ompifgpmddkgmclendfeacglnodjjndh-Default", { workspace = "9 silent" })

o.launch_on_start("foot --app-id=org.omarchy.agent -e opencode")
o.launch_on_start("/opt/zen-browser-bin/zen-bin")
o.launch_on_start("/home/yonathan/.local/zed.app/bin/zed")
o.launch_on_start("remmina")
o.launch_on_start("/home/yonathan/.local/bin/wait-for-notifications omarchy-launch-webapp https://app.slack.com/client")
o.launch_on_start("opencode-desktop")
o.launch_on_start("/home/yonathan/.local/bin/wait-for-notifications /usr/bin/chromium --profile-directory=Default --app-id=faolnafnngnfdaknnbpnkhgohbobgegn")
o.launch_on_start("/home/yonathan/.local/bin/wait-for-notifications /usr/bin/chromium --profile-directory=Default --app-id=ompifgpmddkgmclendfeacglnodjjndh")

-- Point ssh at the systemd user socket-activated ssh-agent (ssh-agent.socket).
hl.env("SSH_AUTH_SOCK", (os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000") .. "/ssh-agent.socket")
