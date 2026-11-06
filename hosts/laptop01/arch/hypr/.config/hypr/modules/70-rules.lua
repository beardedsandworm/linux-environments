
-- Window and workspace rules

-- Suppress maximize events
hl.window_rule({
    name = "suppress-maximize-events",
    match = {
        class = ".*",
    },
    suppress_event = "maximize",
})

-- Fix XWayland drag-and-drop windows
hl.window_rule({
    name = "fix-xwayland-drags",
    match = {
        class = "^$",
        title = "^$",
        xwayland = true,
        float = true,
        fullscreen = false,
        pin = false,
    },
    no_focus = true,
})

-- Position the Hyprland application launcher
hl.window_rule({
    name = "move-hyprland-run",
    match = {
        class = "hyprland-run",
    },
    move = { 20, "monitor_h-120" },
    float = true,
})

-- Disable decorations on floating windows
hl.window_rule({
    name = "disable-decoration-on-floating",
    match = {
        float = true,
    },
    decorate = false,
})
