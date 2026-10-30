-- Phone window gestures: edit and save; Prek applies them within a second.
local p = require("prek")

local touch = { "touch" }
local function swipe(fingers, direction)
    return p.triggers.swipe {
        fingers = fingers, direction = direction,
        travel = "70px", fallback_travel = "0.05norm",
    }
end
local function gesture(action)
    return p.actions.command { argv = { "phone-window-gestures", action } }
end
local function shortcut(id, fingers, direction, action, region)
    return p.rules.define {
        id = id, devices = touch, region = region,
        trigger = swipe(fingers, direction), action = gesture(action),
    }
end
local left = { edge = "left", depth = "24px" }
local right = { edge = "right", depth = "24px" }

return p.shortcuts.new {
    -- Side strips scroll the stack.
    shortcut("scroll-up-left", 1, "up", "scroll-up", left),
    shortcut("scroll-down-left", 1, "down", "scroll-down", left),
    shortcut("scroll-up-right", 1, "up", "scroll-up", right),
    shortcut("scroll-down-right", 1, "down", "scroll-down", right),
    -- Three fingers close the app.
    shortcut("close-up", 3, "up", "close"),
    shortcut("close-down", 3, "down", "close"),
    -- Two fingers reorder and move the app.
    shortcut("window-up", 2, "up", "up"),
    shortcut("window-down", 2, "down", "down"),
    shortcut("window-left", 2, "left", "left"),
    shortcut("window-right", 2, "right", "right"),
}
