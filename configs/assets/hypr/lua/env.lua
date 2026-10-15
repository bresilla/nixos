return function(ctx)
    ctx.colors = ctx.util.read_wal_lua_colors(ctx.home .. "/.cache/wal/colors.lua")

    hl.env("LULE_C", ctx.home .. "/.config/lule")
    hl.env("LULE_A", ctx.home .. "/.cache/lule")
    hl.env("LULE_W", ctx.home .. "/.local/share/lule/wallpapers")
end
