
-- Autostart applications and services
-- Runs once when Hyprland starts, not on config reload.

hl.on("hyprland.start", function()
    -- Desktop services
    hl.exec_cmd("waybar")
    hl.exec_cmd("hyprpaper")
    hl.exec_cmd("swaync")
    hl.exec_cmd("hypridle")

    -- Applications
    hl.exec_cmd("spotify-launcher")
    hl.exec_cmd("fcitx5")
end)
