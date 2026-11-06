
-- Monitor configuration
-- Dell D6000 dock can expose one output under multiple names.

local monitors = {
    { "eDP-1", 1.2 },
    { "DP-2", 1.25 },
    { "DVI-I-1", 1.25 },
    { "DVI-I-2", 1.25 },
    { "DP-1", 1.25 },
}

for _, monitor in ipairs(monitors) do
    hl.monitor({
        output = monitor[1],
        mode = "preferred",
        position = "auto",
        scale = monitor[2],
    })
end
