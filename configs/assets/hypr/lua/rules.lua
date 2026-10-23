return function()
    local function scratchpad_rule(name, title)
        hl.window_rule({
            name = name,
            match = { title = title },
            float = true,
        })
    end

    scratchpad_rule("scratchpad_ask", "ask")
    scratchpad_rule("scratchpad_browsy", "browsy")
    scratchpad_rule("scratchpad_appy", "appy")
    scratchpad_rule("scratchpad_noteing", "noteing")
    scratchpad_rule("scratchpad_main", "main")

    hl.window_rule({
        name = "note_terminal",
        match = { title = "note" },
        float = true,
    })

    hl.window_rule({
        name = "main_terminal",
        match = { title = "main" },
        float = true,
    })

    hl.window_rule({
        name = "spotify",
        match = { class = [[\b[Ss]potify\b]] },
        float = true,
    })

    hl.window_rule({
        name = "astrocraft",
        match = { title = "astrocraft" },
        float = true,
    })

    hl.window_rule({ match = { class = ".*float.*" }, float = true })
    hl.window_rule({ match = { class = ".*mpv.*" }, float = true })
    hl.window_rule({ match = { class = ".*scrcpy.*" }, float = true })
    hl.window_rule({ match = { class = ".*matplotlib.*" }, float = true })
    hl.window_rule({ match = { class = ".*opencv.*" }, float = true })
    hl.window_rule({ match = { class = ".*Spotify.*" }, float = true })

    -- Dialogs float at the size the app asks for, which for these is too small to read:
    -- Blender's own windows (titled "Blender File View", "Blender Preferences", …; the main
    -- window's title starts with the file) and the GTK portal's file chooser.
    local dialog = { float = true, size = "monitor_w*0.7 monitor_h*0.75", center = true }
    hl.window_rule({
        name = "blender_dialogs",
        match = { class = "^blender$", title = "^Blender " },
        float = dialog.float,
        size = dialog.size,
        center = dialog.center,
    })
    hl.window_rule({
        name = "file_chooser",
        match = { class = [[^xdg-desktop-portal-gtk$]] },
        float = dialog.float,
        size = dialog.size,
        center = dialog.center,
    })

    -- Keep the SDL/Flatpak RDP client in the normal tiling layout.
    hl.window_rule({
        name = "freerdp_sdl_tile",
        match = { class = [[^(com\.freerdp\.FreeRDP|sdl-freerdp|sdl-freerdp3)$]] },
        tile = true,
    })
end
