
-- Keyboard, mouse, touchpad, and gestures

hl.config({
    input = {
        kb_layout = "us",
        kb_variant = "",
        kb_model = "",
        kb_options = "caps:escape",
        kb_rules = "",

        numlock_by_default = true,
        follow_mouse = 1,
        sensitivity = 0,

        touchpad = {
            natural_scroll = false,
        },
    },
})

-- Three-finger horizontal swipe to change workspaces

hl.gesture({
    fingers = 3,
    direction = "horizontal",
    action = "workspace",
})

-- Device-specific mouse sensitivity

hl.device({
    name = "epic-mouse-v1",
    sensitivity = -0.5,
})
