-- Equal columns, then stack new windows down each column from left to right.
-- Ultrawides: 1 2 3 / 4 5 6 / ...; other screens: 1 2 / 3 4 / ...
local WIDE_ASPECT_RATIO = 2.0
local MIN_COLUMN_WIDTH = 800
local MIN_RESIZE_WIDTH = 160
local MIN_RESIZE_HEIGHT = 100
local BORDER_GRAB_AREA = 18 -- border_size + extend_border_grab_area in options.lua

local workspaces = {}
local drag = nil

local function equal_cuts(count)
    local cuts = {}
    for index = 0, count do
        cuts[index + 1] = index / count
    end
    return cuts
end

local function workspace_key(ctx)
    for _, target in ipairs(ctx.targets) do
        local window = target.window
        local workspace = window and window.workspace
        if workspace then
            return tostring(workspace.id)
        end
    end
    -- Layout targets need not expose a window (for example, a group).
    return "area:" .. ctx.area.x .. ":" .. ctx.area.y
end

local function move_cut(cuts, boundary, value, minimum)
    if not boundary or boundary < 1 or boundary >= #cuts - 1 then
        return
    end
    -- Keep both neighbours visible, including on very small work areas.
    local lower, upper = cuts[boundary], cuts[boundary + 2]
    minimum = math.min(minimum, (upper - lower) / 2)
    cuts[boundary + 1] = math.max(lower + minimum, math.min(upper - minimum, value))
end

local function apply_drag(state)
    if not drag or drag.state ~= state then
        return
    end
    local cursor = hl.get_cursor_pos()
    if not cursor then
        return
    end
    if drag.column then
        move_cut(state.widths, drag.column,
            drag.width + drag.direction_x * (cursor.x - drag.x) / state.area.w,
            MIN_RESIZE_WIDTH / state.area.w)
    end
    if drag.row then
        move_cut(state.heights[drag.slot.column], drag.row,
            drag.height + drag.direction_y * (cursor.y - drag.y) / state.area.h,
            MIN_RESIZE_HEIGHT / state.area.h)
    end
end

local function begin_resize(border_only)
    drag = nil
    local window = hl.get_active_window()
    local cursor = hl.get_cursor_pos()
    if not window or not cursor or window.floating or window.fullscreen ~= 0 then
        return
    end
    local workspace = window.workspace
    local state = workspace and workspaces[tostring(workspace.id)]
    local slot = state and state.slots[window.address]
    if not slot then
        return
    end

    local at, size = window.at, window.size
    if cursor.x < at.x - BORDER_GRAB_AREA or cursor.x > at.x + size.x + BORDER_GRAB_AREA
        or cursor.y < at.y - BORDER_GRAB_AREA or cursor.y > at.y + size.y + BORDER_GRAB_AREA then
        return
    end

    local left = cursor.x < at.x + size.x / 2
    local top = cursor.y < at.y + size.y / 2
    local column = left and slot.column - 1 or slot.column
    local row = top and slot.row - 1 or slot.row
    local rows = #state.heights[slot.column] - 1
    local direction_x, direction_y = 1, 1

    if border_only then
        -- Only an actual border click should arm resizing; normal clicks and
        -- text selection inside the client continue to pass through untouched.
        local outside_x = cursor.x <= at.x or cursor.x >= at.x + size.x
        local outside_y = cursor.y <= at.y or cursor.y >= at.y + size.y
        if not outside_x then column = nil end
        if not outside_y then row = nil end
    else
        -- Alt-dragging an outer corner adjusts the nearest internal divider.
        if column == 0 or column == state.columns then direction_x = -1 end
        if row == 0 or row == rows then direction_y = -1 end
        column = math.max(1, math.min(state.columns - 1, column))
        row = math.max(1, math.min(rows - 1, row))
    end

    if column and (column < 1 or column >= state.columns) then column = nil end
    if row and (row < 1 or row >= rows) then row = nil end
    if not column and not row then
        return
    end
    drag = {
        state = state,
        slot = slot,
        x = cursor.x,
        y = cursor.y,
        column = column,
        row = row,
        direction_x = direction_x,
        direction_y = direction_y,
        width = column and state.widths[column + 1],
        height = row and state.heights[slot.column][row + 1],
    }
end

-- Hyprland 0.55's Lua resizeTarget calls recalculate without forwarding the
-- delta/corner. Observe press/release and read the cursor during those native
-- recalculations instead. Keep native dragging, focus, and input delivery.
hl.bind("mouse:272", function() begin_resize(true) end,
    { non_consuming = true, ignore_mods = true })
hl.bind("ALT + mouse:272", function() begin_resize(false) end,
    { non_consuming = true })
hl.bind("mouse:272", function() drag = nil end,
    { release = true, non_consuming = true, ignore_mods = true, submap_universal = true })

hl.on("workspace.removed", function(workspace)
    local key = tostring(workspace.id)
    if drag and drag.state == workspaces[key] then drag = nil end
    workspaces[key] = nil
end)

hl.layout.register("adaptive_columns", {
    recalculate = function(ctx)
        local count = #ctx.targets
        local area = ctx.area

        if count == 0 or area.w <= 0 or area.h <= 0 then
            return
        end

        -- Use logical workspace dimensions so scaling and reserved space count.
        local wide = area.w / area.h >= WIDE_ASPECT_RATIO
            and area.w / 3 >= MIN_COLUMN_WIDTH
        local columns = math.min(count, wide and 3 or 2)
        local key = workspace_key(ctx)
        local state = workspaces[key] or { heights = {}, slots = {} }
        workspaces[key] = state

        local members = {}
        for index, target in ipairs(ctx.targets) do
            local window = target.window
            members[index] = window and window.address or tostring(target.index or index)
        end
        local signature = table.concat(members, ",")
            .. ":" .. area.x .. ":" .. area.y .. ":" .. area.w .. ":" .. area.h
        if drag and drag.state == state and state.signature ~= signature then
            drag = nil
        end
        state.signature = signature
        state.area = area
        if state.columns ~= columns then
            state.widths = equal_cuts(columns)
            state.heights = {}
        end
        state.columns = columns
        for column = 1, columns do
            local rows = math.floor((count - column) / columns) + 1
            if not state.heights[column] or #state.heights[column] ~= rows + 1 then
                state.heights[column] = equal_cuts(rows)
            end
        end
        apply_drag(state)
        state.slots = {}

        for index, target in ipairs(ctx.targets) do
            local column = (index - 1) % columns + 1
            local row = math.floor((index - 1) / columns) + 1
            local heights = state.heights[column]

            -- Each column fills its own height, even when its neighbours have
            -- fewer windows. Hyprland applies gaps and borders through place().
            target:place({
                x = area.x + area.w * state.widths[column],
                y = area.y + area.h * heights[row],
                w = area.w * (state.widths[column + 1] - state.widths[column]),
                h = area.h * (heights[row + 1] - heights[row]),
            })
            state.slots[members[index]] = { column = column, row = row }
        end
    end,
})
