
-- Wormlogic Hyprland configuration
-- Host: laptop01
-- Managed through GNU Stow

-- Monitors
require("modules.00-monitors")

-- Default applications
local programs = require("modules.10-programs")

-- Autostart
require("modules.20-autostart")

-- Environment variables
require("modules.30-env")

-- Appearance and animations
require("modules.40-appearance")

-- Input devices and gestures
require("modules.50-input")

-- Keybindings
local configure_binds = require("modules.60-binds")
configure_binds(programs)

-- Window rules
require("modules.70-rules")

-- XWayland compatibility
require("modules.80-xwayland")
