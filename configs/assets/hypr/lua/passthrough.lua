-- Remote desktops get every key: while an RDP window is focused (focus follows the mouse),
-- Hyprland switches to an empty submap, so its own binds stop and the remote session's
-- Hyprland receives them. Any other window brings the binds back.
return function(ctx)
    local remote_classes = {
        ["xfreerdp"] = true,
        ["xfreerdp3"] = true,
        ["com.freerdp.FreeRDP"] = true,
        ["sdl-freerdp"] = true,
        ["sdl-freerdp3"] = true,
    }

    -- A submap only exists once it has a bind; its one bind hands the local binds back while
    -- still over the remote window, until focus moves again.
    hl.define_submap("passthrough", function()
        hl.bind("SUPER + ALT + Escape", hl.dsp.submap("reset"))
    end)

    local function follow(window)
        local remote = window ~= nil and remote_classes[window.class] == true
        local current = hl.get_current_submap()
        if remote and current ~= "passthrough" then
            hl.dispatch(hl.dsp.submap("passthrough"))
        elseif not remote and current == "passthrough" then
            hl.dispatch(hl.dsp.submap("reset"))
        end
    end

    hl.on("window.active", follow)
    hl.on("window.close", function()
        follow(hl.get_active_window())
    end)
end
