return function(ctx)
    local bind_exec = ctx.util.bind_exec
    local scratchpads = dofile(ctx.config_dir .. "/lua/scratchpads.lua")(ctx)

    local super = "SUPER"
    local meta = "ALT"
    local meta_mod = "ALT"
    local hyper = "Hyper_L"
    local menu = "CTRL"

    local super_meta = super .. " + " .. meta
    local super_meta_shift = super .. " + " .. meta_mod .. " + SHIFT"

    -- One font and padding on every screen, so terminals look the same everywhere.
    local terminal_font_size = "13"
    local terminal_padding = "24"

    local function kitty_cmd(args)
        local cmd = "kitty"
            .. " -o font_size=" .. terminal_font_size
            .. " -o window_padding_width=" .. terminal_padding

        if args and args ~= "" then
            cmd = cmd .. " " .. args
        end

        return cmd
    end

    bind_exec(super .. " + L", "morf lock")

    bind_exec(super_meta .. " + P", "doas chvt 2")
    scratchpads.bind(super_meta .. " + Backspace", "ask", function()
        return kitty_cmd("--title ask -e aichat")
    end, {
        size = { "monitor_h*0.8", "monitor_h*0.8" },
    })
    -- browsy and appy, as morf's launcher (the kitty scratchpads they
    -- were are in binds.lua.bak-launcher).
    bind_exec(super_meta .. " + Space", "morf ipc call launcher web")
    bind_exec(super_meta .. " + Return", "morf ipc call launcher apps")
    -- morf's on-screen keyboard (it also comes up by itself when a text
    -- field wants input and no keyboard is attached).
    bind_exec(super_meta .. " + K", "morf ipc call keyboard toggle")
    -- morf's menu of the focused window, over it.
    bind_exec("F8", "morf ipc call window_menu toggle")
    bind_exec(super_meta .. " + F9", ctx.home .. "/.local/sbin/lule_switch")

    hl.bind(super .. " + Escape", hl.dsp.window.close())

    hl.bind(super .. " + Return", function()
        hl.exec_cmd(kitty_cmd())
    end)
    hl.bind(meta .. " + Return", function()
        hl.exec_cmd(kitty_cmd())
    end)

    scratchpads.bind(super .. " + Space", "noteing", function()
        return kitty_cmd("--title noteing")
    end, {
        size = { "monitor_w*0.78", "monitor_h*0.54" },
    })
    scratchpads.bind(meta .. " + Space", "main", function()
        return kitty_cmd("--title main")
    end, {
        size = { "monitor_w*0.78", "monitor_h*0.54" },
    })

    scratchpads.bind(super .. " + M", "spotify", "flatpak run com.spotify.Client", {
        size = { "90%", "60%" },
    })
    scratchpads.bind(meta .. " + M", "spotify-premium", "flatpak run com.spotify.Client", {
        size = { "90%", "60%" },
    })

    hl.gesture({ fingers = 4, direction = "vertical", action = "workspace" })

    hl.bind(super .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
    hl.bind(meta_mod .. " + mouse:272", hl.dsp.window.resize(), { mouse = true })

    hl.bind(super_meta .. " + Up", function()
        ctx.focus_workspace_delta(-1)
    end)
    hl.bind(super_meta .. " + Down", function()
        ctx.focus_workspace_delta(1)
    end)

    hl.bind(super_meta_shift .. " + Up", function()
        ctx.move_window_to_workspace_delta(-1)
    end)
    hl.bind(super_meta_shift .. " + Down", function()
        ctx.move_window_to_workspace_delta(1)
    end)

    hl.bind(super .. " + left", hl.dsp.focus({ direction = "left" }))
    hl.bind(super .. " + right", hl.dsp.focus({ direction = "right" }))
    hl.bind(super .. " + up", hl.dsp.focus({ direction = "up" }))
    hl.bind(super .. " + down", hl.dsp.focus({ direction = "down" }))

    hl.bind(super .. " + f", hl.dsp.window.float({ action = "toggle" }))
    hl.bind(super .. " + s", hl.dsp.window.fullscreen())

    bind_exec("XF86AudioMute", "pamixer -t", { repeating = true })
    bind_exec("XF86AudioRaiseVolume", "pamixer -i 2", { repeating = true })
    bind_exec("XF86AudioLowerVolume", "pamixer -d 2", { repeating = true })
    bind_exec("XF86AudioPlay", "playerctl next", { repeating = true })

    bind_exec("XF86MonBrightnessDown", ctx.home .. "/.local/sbin/bright -2")
    bind_exec("XF86MonBrightnessUp", ctx.home .. "/.local/sbin/bright +2")

    bind_exec("Print", "morf ipc call capture open")

    bind_exec(menu .. " + Space", "mpv_control cycle")
    bind_exec(menu .. " + comma", "mpv_control backwards 10")
    bind_exec(menu .. " + period", "mpv_control forewards 10")

    bind_exec(super .. " + F9", ctx.home .. "/.local/sbin/lule_create")

    _ = hyper
end
