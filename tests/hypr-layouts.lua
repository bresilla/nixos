-- Run from the repository root: oslo --norc tests/hypr-layouts.lua
local bindings, events, provider
local active, cursor
local checks = 0

local function load_layout()
    bindings, events = {}, {}
    active, cursor = nil, nil
    hl = {
        layout = { register = function(name, methods)
            assert(name == "adaptive_columns")
            provider = methods
        end },
        bind = function(keys, callback, options)
            assert(options.non_consuming, "mouse observers must preserve native input")
            bindings[#bindings + 1] = { keys = keys, callback = callback, options = options }
        end,
        on = function(name, callback) events[name] = callback end,
        get_active_window = function() return active end,
        get_cursor_pos = function() return cursor end,
    }
    dofile("configs/assets/hypr/lua/layouts.lua")
end

local function close(actual, expected)
    assert(math.abs(actual - expected) < 0.000001, actual .. " ~= " .. expected)
end

local function context(count, area, workspace)
    local ctx = { area = area, targets = {}, boxes = {} }
    for index = 1, count do
        local window = {
            address = workspace .. ":" .. index,
            workspace = { id = workspace }, floating = false, fullscreen = 0,
        }
        ctx.targets[index] = {
            index = index, window = window,
            place = function(_, box)
                ctx.boxes[index] = box
                window.at = { x = box.x + 13, y = box.y + 13 }
                window.size = { x = box.w - 26, y = box.h - 26 }
            end,
        }
    end
    provider.recalculate(ctx)
    return ctx
end

local function press(alt)
    for _, binding in ipairs(bindings) do
        if not binding.options.release and (binding.keys == "mouse:272" or alt) then
            binding.callback()
        end
    end
end

local function release()
    for _, binding in ipairs(bindings) do
        if binding.options.release then
            assert(binding.options.ignore_mods and binding.options.submap_universal)
            binding.callback()
        end
    end
end

local function start(ctx, index, x, y, alt)
    active = ctx.targets[index].window
    cursor = { x = x, y = y }
    press(alt)
end

local function move(ctx, x, y)
    cursor = { x = x, y = y }
    -- Native resizeTarget calls this callback on mouse movement in Hyprland.
    provider.recalculate(ctx)
end

local function geometry(ctx)
    local total = 0
    for index, box in ipairs(ctx.boxes) do
        assert(box.w > 0 and box.h > 0)
        assert(box.x >= ctx.area.x - 0.000001 and box.y >= ctx.area.y - 0.000001)
        assert(box.x + box.w <= ctx.area.x + ctx.area.w + 0.000001)
        assert(box.y + box.h <= ctx.area.y + ctx.area.h + 0.000001)
        total = total + box.w * box.h
        for previous = 1, index - 1 do
            local other = ctx.boxes[previous]
            local overlap_x = math.min(box.x + box.w, other.x + other.w) - math.max(box.x, other.x)
            local overlap_y = math.min(box.y + box.h, other.y + other.h) - math.max(box.y, other.y)
            assert(overlap_x < 0.000001 or overlap_y < 0.000001, "windows overlap")
        end
    end
    if #ctx.targets > 0 then close(total, ctx.area.w * ctx.area.h) end
    checks = checks + 1
end

load_layout()
local screens = {
    { x = 10, y = 10, w = 3420, h = 1420, columns = 3 },
    { x = 3450, y = 10, w = 3420, h = 1420, columns = 3 },
    { x = 1722, y = 1450, w = 3436, h = 2140, columns = 2 },
    { x = -1920, y = 0, w = 1900, h = 1060, columns = 2 },
    { x = 0, y = 0, w = 2273, h = 940, columns = 2 },
    { x = 0, y = 0, w = 1060, h = 1900, columns = 2 },
    { x = 0, y = 0, w = 2400, h = 1200, columns = 3 },
    { x = 0, y = 0, w = 2399, h = 1100, columns = 2 },
    { x = 0, y = 0, w = 2400, h = 1201, columns = 2 },
}
for screen, area in ipairs(screens) do
    for count = 0, 30 do
        local ctx = context(count, area, screen)
        local columns = math.min(count, area.columns)
        assert(#ctx.boxes == count)
        for index, box in ipairs(ctx.boxes) do
            close(box.w, area.w / columns)
            close(box.x, area.x + ((index - 1) % columns) * area.w / columns)
            if index <= columns then close(box.y, area.y) end
        end
        geometry(ctx)
    end
end

load_layout()
local area = { x = 100, y = 200, w = 3000, h = 1200 }
local ctx = context(4, area, 1)
close(ctx.boxes[1].h, 600)
close(ctx.boxes[2].h, 1200)
close(ctx.boxes[4].y, 800)

-- Border drag: widen the left column; all its rows follow the same divider.
start(ctx, 1, 1088, 500, false)
move(ctx, 1288, 500)
close(ctx.boxes[1].w, 1200)
close(ctx.boxes[4].w, 1200)
close(ctx.boxes[2].x, 1300)
close(ctx.boxes[2].w, 800)
geometry(ctx)
release()
move(ctx, 1588, 500)
close(ctx.boxes[1].w, 1200)

-- Horizontal divider drag only changes the selected column's stacked heights.
start(ctx, 1, 500, 788, false)
move(ctx, 500, 988)
close(ctx.boxes[1].h, 800)
close(ctx.boxes[4].h, 400)
close(ctx.boxes[4].y, 1000)
close(ctx.boxes[2].h, 1200)
geometry(ctx)
release()

-- Ordinary client clicks, floating/fullscreen windows, and distant clicks do
-- not turn mouse movement or unrelated recalculations into a resize.
for _, mode in ipairs({ "ordinary", "floating", "fullscreen", "distant" }) do
    active = ctx.targets[1].window
    active.floating = mode == "floating"
    active.fullscreen = mode == "fullscreen" and 1 or 0
    local x = mode == "distant" and -1000 or 500
    start(ctx, 1, x, 500, mode ~= "ordinary")
    move(ctx, 600, 550)
    close(ctx.boxes[1].w, 1200)
    close(ctx.boxes[1].h, 800)
    release()
end
active.floating, active.fullscreen = false, 0

-- Alt-drag an outer corner: dragging out grows the selected window, even
-- though the internal divider must travel in the opposite direction.
start(ctx, 1, 200, 300, true)
move(ctx, 100, 200)
close(ctx.boxes[1].w, 1300)
close(ctx.boxes[1].h, 900)
geometry(ctx)
release()
start(ctx, 3, 3000, 1300, true)
move(ctx, 3100, 1400)
close(ctx.boxes[3].w, 1100)
geometry(ctx)
release()

-- Minimum sizes clamp extreme drags, preserving a complete, non-overlapping
-- partition of the workspace, and reversing the drag restores the divider.
start(ctx, 1, 1388, 500, false)
move(ctx, 100000, 500)
close(ctx.boxes[2].w, 160)
geometry(ctx)
move(ctx, 1388, 500)
close(ctx.boxes[1].w, 1300)
release()
start(ctx, 1, 500, 1088, false)
move(ctx, 500, 100000)
close(ctx.boxes[4].h, 100)
geometry(ctx)
release()

-- Adjustments survive recalculation and stay local to their workspace.
local other = context(4, area, 2)
close(other.boxes[1].w, 1000)
close(other.boxes[1].h, 600)
provider.recalculate(ctx)
close(ctx.boxes[1].w, 1300)

-- Adding a window keeps column widths but splits the newly stacked column
-- equally. Closing/moving a target or changing scale cancels an active drag.
local added = context(5, area, 1)
close(added.boxes[1].w, 1300)
close(added.boxes[2].h, 600)
geometry(added)
start(added, 1, 1388, 500, false)
cursor = { x = 1488, y = 500 }
local removed = context(4, area, 1)
close(removed.boxes[1].w, 1300)
release()
events["workspace.removed"]({ id = 1 })
local recreated = context(4, area, 1)
close(recreated.boxes[1].w, 1000)
geometry(recreated)

-- Groups/targets without a window and empty/zero-sized workspaces are valid.
recreated.targets[1].window = nil
provider.recalculate(recreated)
geometry(recreated)
context(4, { x = 0, y = 0, w = 0, h = 100 }, 3)
context(4, { x = 0, y = 0, w = 100, h = 0 }, 3)
print("PASS: " .. checks .. " geometry cases, native-drag simulation, limits, persistence, and input isolation")
