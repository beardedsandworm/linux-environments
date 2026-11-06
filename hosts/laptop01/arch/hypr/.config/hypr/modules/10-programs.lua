
-- Default applications

local programs = {
    terminal = "alacritty",
    fileManager = "dolphin",
    menu = "wofi --show drun",
}

-- Fix Dolphin application menu on Arch
hl.env("XDG_MENU_PREFIX", "arch-")

-- Export for use in 60-binds.lua
return programs
