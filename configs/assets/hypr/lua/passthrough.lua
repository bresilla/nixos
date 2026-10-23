-- Remote desktops get every key: while an RDP window is focused and the pointer is over it,
-- Hyprland switches to a submap without the local binds, so the remote session's Hyprland
-- receives them. Moving the pointer off the window (or focusing another) brings them back.
-- Scratchpads stay local in both cases.
return function(ctx)
    local remote_classes = {
        ["xfreerdp"] = true,
        ["xfreerdp3"] = true,
        ["com.freerdp.FreeRDP"] = true,
        ["sdl-freerdp"] = true,
        ["sdl-freerdp3"] = true,
    }

    -- A submap only exists once it has a bind; the escape bind hands the local binds back
    -- while still over the remote window, until the pointer or focus moves again.
    hl.define_submap("passthrough", function()
        hl.bind("SUPER + ALT + Escape", hl.dsp.submap("reset"))
        for _, binding in ipairs(ctx.scratchpads and ctx.scratchpads.bindings or {}) do
            hl.bind(binding.keys, binding.toggle)
        end
    end)

    local function pointer_inside(window)
        local cursor = hl.get_cursor_pos()
        local at, size = window.at, window.size
        if not cursor or not at or not size then
            return false
        end
        return cursor.x >= at.x and cursor.x < at.x + size.x and cursor.y >= at.y and cursor.y < at.y + size.y
    end

    -- Set by the escape bind's reset; cleared once the pointer leaves or focus changes,
    -- so the poll does not switch straight back into passthrough.
    local released = nil

    local function follow()
        local window = hl.get_active_window()
        local remote = window ~= nil and remote_classes[window.class] == true and pointer_inside(window)
        local current = hl.get_current_submap()
        local address = window and window.address

        if not remote or released ~= address then
            released = nil
        end

        if remote and current ~= "passthrough" and released == nil then
            hl.dispatch(hl.dsp.submap("passthrough"))
        elseif not remote and current == "passthrough" then
            hl.dispatch(hl.dsp.submap("reset"))
        end
    end

    hl.on("keybinds.submap", function(name)
        if name ~= "passthrough" and hl.get_current_submap() ~= "passthrough" then
            local window = hl.get_active_window()
            if window and remote_classes[window.class] and pointer_inside(window) then
                released = window.address
            end
        end
    end)

    hl.on("window.active", follow)
    hl.on("window.close", follow)
    -- No pointer event exists, so the pointer position is polled.
    hl.timer(follow, { timeout = 100, type = "repeat" })
end
