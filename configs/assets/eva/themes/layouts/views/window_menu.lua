-- The window menu (shell/window_menu.lua): five cards in a cross over the
-- focused window, its frame marked on the desk, every side card holding
-- its own grid of buttons. The cards fan out from the middle as it opens,
-- their buttons settle in after them, and the whole cross glides along as
-- the window moves or changes size. Only kit calls and theme tokens draw.
local morf = require("morf")
local ui = require("morf.ui")
local theme = require("theme")
local kit = require("kit")
local L = require("themes.layouts.parts")
local C = theme.color
local V = {}

local CW, MID_H = 320, 96
local GX, GY = 40, 34
local W = 3 * CW + 2 * GX
local HEAD, BH, BG, PAD = 72, 30, 6, 14
local COLUMNS = { top = 3, left = 5, right = 2, bottom = 2 }
local MAX_BUTTONS = 12
local MARGIN = 16
local GLIDE = { duration = 420, easing = "out_cubic" }
local FADE = { duration = 220, easing = "out_cubic" }
local X = { left = 0, top = CW + GX, center = CW + GX, bottom = CW + GX, right = 2 * (CW + GX) }
local ARROWS = {
  top = { "arrow_upward" }, bottom = { "arrow_downward" }, left = { "arrow_back" }, right = { "arrow_forward" },
}

--- `buttons` placed on a grid of `columns`: each one's column, row and span.
local function grid(buttons, columns)
  local out, col, row = {}, 0, 0
  for i, b in ipairs(buttons) do
    local span = math.min(b.span or 1, columns)
    if col + span > columns then col, row = 0, row + 1 end
    out[i] = { col = col, row = row, span = span }
    col = col + span
  end
  return out, (#buttons > 0) and row + 1 or 0
end

function V.build(model)
  local opened = model.opened
  local layout = {}
  for _, card in ipairs(model.CARDS) do
    local key = card.key
    layout[key] = function()
      local buttons = model.buttons(key)
      local cells, rows = grid(buttons, COLUMNS[key] or 1)
      return { buttons = buttons, cells = cells, rows = rows }
    end
  end
  local function height(key)
    if key == "center" then return MID_H end
    local rows = layout[key]().rows
    return HEAD + rows * BH + math.max(0, rows - 1) * BG + PAD
  end
  local function card_y(key)
    local mid = height("top") + GY
    if key == "top" then return 0 end
    if key == "center" then return mid end
    if key == "bottom" then return mid + MID_H + GY end
    return mid + MID_H / 2 - height(key) / 2
  end
  local function total_h() return height("top") + GY + MID_H + GY + height("bottom") end

  -- -------------------------------------------------------------- cards --
  local cards, boxes = {}, {}
  for _, card in ipairs(model.CARDS) do
    local key, mid = card.key, card.key == "center"
    local function summary(i) return function() return model.summary(key)[i] or "" end end
    local children = {
      kit.card { anchors = { fill = true } },
      L.label { x = 14, y = 12, width = 22, text = card.number, font_size = L.SIZE.label, color = kit.ink("lo") },
      kit.text { x = 42, y = 8, width = CW - 56, elide = "right", text = card.title:upper(),
        font_size = theme.size.normal, font_weight = 600, color = kit.ink("hi") },
      L.rule { x = 12, y = 34, width = CW - 24 },
    }
    if mid then
      -- Its header is lit, as the reference's: the window's own card.
      table.insert(children, 2, kit.surface { x = 6, y = 6, height = 26, width = CW - 12, color = kit.signal("accent") })
      children[3].color = function() return C.onPrimary end
      children[4].color = function() return C.onPrimary end
      children[#children + 1] = kit.text { x = 14, y = 44, width = CW - 28, elide = "right", text = summary(1),
        font_size = theme.size.normal, color = kit.ink("hi"), horizontal_alignment = "center" }
      children[#children + 1] = L.label { x = 14, y = 68, width = CW - 28, elide = "right", text = summary(2),
        horizontal_alignment = "center", color = kit.ink("lo") }
    else
      children[#children + 1] = L.label { x = 16, y = 44, width = CW - 32, elide = "right", font_size = L.SIZE.body,
        text = summary(1), color = kit.ink("lo") }
      local cols = COLUMNS[key]
      local bw = (CW - 2 * PAD - (cols - 1) * BG) / cols
      for i = 1, MAX_BUTTONS do
        local function button() return layout[key]().buttons[i] end
        local function cell() return layout[key]().cells[i] or { col = 0, row = 0, span = 1 } end
        local function id() local b = button() return b and (key .. ":" .. b.key) or "" end
        local function lit() local b = button() return b ~= nil and (b.on == true or b.primary == true) end
        local ink = require("themes.layouts.rows").ink(lit, true, C.onSurface)
        local area
        area = kit.action { id = "window-menu-" .. key .. "-" .. i,
          accessible_name = function() local b = button() return b and b.label or "" end,
          x = function() return PAD + cell().col * (bw + BG) end,
          y = function() return HEAD + cell().row * (BH + BG) end,
          width = function() local s = cell().span return s * bw + (s - 1) * BG end, height = BH,
          visible = function() return button() ~= nil end,
          enabled = function() return opened:get() and button() ~= nil end,
          cursor = "pointer",
          on_entered = function() if button() then model.focus:set(id()) end end,
          on_clicked = function() model.press(id()) end,
          L.label { anchors = { center_in = true }, width = function() local s = cell().span return s * bw + (s - 1) * BG - 8 end,
            horizontal_alignment = "center", elide = "right", font_size = L.SIZE.body, color = ink,
            text = function() local b = button() return b and b.label:upper() or "" end },
          ui.Item { anchors = { fill = true }, visible = function() return model.focus:get() == id() and id() ~= "" end,
            L.decor_box("corners", { length = 6, weight = 2, inset = -2, color = kit.stroke("hot") }) },
        }
        ui.reparent(kit.state_surface { id = "window-menu-" .. key .. "-" .. i .. "-shape", area = area, on = lit,
          height = BH, tone = "primary", z = -1 }, area)
        children[#children + 1] = area
        boxes[#boxes + 1] = { key = key, id = id, area = area }
      end
    end
    -- Lit while the keys are on one of its buttons.
    children[#children + 1] = ui.Item { anchors = { fill = true },
      visible = function() return (model.focus:get():match("^([^:]+):") or "") == key end,
      L.decor_box("corners", { length = 10, weight = 2, inset = -4, color = kit.stroke("hot") }) }
    children.id = "window-menu-card-" .. key
    children.width, children.height = CW, function() return height(key) end
    children.x = function() return opened:get() and X[key] or X.center end
    children.y = function()
      if opened:get() then return card_y(key) end
      return card_y("center") + MID_H / 2 - height(key) / 2
    end
    children.opacity = function() return opened:get() and 1 or 0 end
    children.behavior = { x = GLIDE, y = GLIDE, height = GLIDE, opacity = FADE }
    children[#children + 1] = ui.MouseArea { anchors = { fill = true }, z = -2 }
    cards[key] = ui.Item(children)
  end

  -- What the keys move between: every button on show, and the middle card.
  model.attach(function()
    local out = {}
    for _, b in ipairs(boxes) do
      local id = b.id()
      if id ~= "" then
        local a = b.area
        out[#out + 1] = { id = id, x = X[b.key] + (a.x or 0), y = card_y(b.key) + (a.y or 0),
          width = a.width or 0, height = BH }
      end
    end
    out.center = { x = X.center, y = card_y("center"), width = CW, height = MID_H }
    return out
  end)

  -- ------------------------------------------------------------- arrows --
  local arrows = {}
  for key, a in pairs(ARROWS) do
    local function place()
      local mid = card_y("center")
      if key == "top" then return W / 2 - 14, mid - GY / 2 - 14 end
      if key == "bottom" then return W / 2 - 14, mid + MID_H + GY / 2 - 14 end
      if key == "left" then return CW + GX / 2 - 14, mid + MID_H / 2 - 14 end
      return W - CW - GX / 2 - 14, mid + MID_H / 2 - 14
    end
    arrows[#arrows + 1] = ui.Item { id = "window-menu-arrow-" .. key, width = 28, height = 28,
      x = function() return (place()) end, y = function() return select(2, place()) end,
      opacity = function() return opened:get() and 0.55 or 0 end, behavior = { opacity = FADE, y = GLIDE },
      L.decor_box("corners", { width = 28, height = 28, length = 5, color = kit.stroke("mark") }),
      kit.icon(a[1], 16, kit.ink("hi"), { anchors = { center_in = true } }) }
  end

  -- ------------------------------------------------------------ the box --
  local keys = ui.Item { id = "window-menu-keys", width = 1, height = 1, tab_navigation = false,
    on_key_pressed = model.key }
  local function rect() return model.rect() or { x = 0, y = 0, width = 0, height = 0 } end
  local box_children = { id = "window-menu", width = W, height = total_h,
    accessible_role = "dialog", accessible_name = "Window menu" }
  for _, n in ipairs(arrows) do box_children[#box_children + 1] = n end
  for _, key in ipairs { "top", "left", "right", "bottom", "center" } do box_children[#box_children + 1] = cards[key] end
  box_children[#box_children + 1] = keys
  local box = ui.Item(box_children)
  local function box_at()
    local r, sw, sh = rect(), model.screen()
    local h = total_h()
    return math.floor(math.max(MARGIN, math.min(sw - W - MARGIN, r.x + r.width / 2 - W / 2))),
      math.floor(math.max(MARGIN, math.min(sh - h - MARGIN, r.y + r.height / 2 - h / 2)))
  end

  -- The window itself, framed on the desk under the menu and taped over:
  -- the tape cut to the window's own rounded corners and running along it
  -- while the menu is open, a band's width wider than the window so it
  -- never shows a bare edge; the frame on the window's border.
  local TAPE = 64
  -- Drawn a band past every edge, so where its strokes end (square to
  -- the stroke, slanted to the edge) is outside, and the window's own
  -- corners cut it.
  local function tape_w() return rect().width + TAPE * 3 end
  local function tape_h() return math.max(1, rect().height) + TAPE * 2 end
  local tape = ui.Item { id = "window-menu-tape", x = -TAPE * 2, y = -TAPE, width = tape_w, height = tape_h,
    loop = function()
      if not opened:get() then return nil end
      return { translate_x = { from = 0, to = TAPE, duration = 1600, easing = "linear" } }
    end,
    L.decor_box("tape", { width = tape_w, height = tape_h, spacing = TAPE, weight = TAPE * 0.45,
      color = function() return kit.signal("accent")():alpha(0.08) end }) }
  local outline = kit.surface { id = "window-menu-outline", anchors = { fill = true }, color = "transparent",
    border_width = 2, radius = function() return model.rounding() + model.border() end,
    border_color = kit.stroke("hot") }
  morf.effect("material.window_menu.outline", function()
    outline.anchors = { fill = true, margins = -model.border() }
  end, { owner = outline })
  local frame = ui.Item { id = "window-menu-frame",
    opacity = function() return opened:get() and 1 or 0 end, behavior = { opacity = FADE },
    ui.ClipRect { anchors = { fill = true }, radius = model.rounding, color = "transparent", tape },
    outline,
    L.decor_box("corners", { length = 18, weight = 2, inset = -6, color = kit.stroke("hot") }),
  }

  -- Where it opens it is put at once; while open on the same window it
  -- follows that window as it moves or changes size. Shut, it stays where
  -- it folded away.
  local shown_at, follow = nil, nil
  morf.effect("material.window_menu.place", function()
    local open, address = opened:get(), model.address:get()
    local r = rect()
    local bx, by = box_at()
    if not open then shown_at = nil return end
    if follow then follow:stop() follow = nil end
    if shown_at ~= address then
      shown_at = address
      box.x, box.y = bx, by
      frame.x, frame.y, frame.width, frame.height = r.x, r.y, r.width, r.height
      return
    end
    follow = morf.animation.play { { parallel = {
      { node = box, property = "x", to = bx, duration = GLIDE.duration, easing = GLIDE.easing },
      { node = box, property = "y", to = by, duration = GLIDE.duration, easing = GLIDE.easing },
      { node = frame, property = "x", to = r.x, duration = GLIDE.duration, easing = GLIDE.easing },
      { node = frame, property = "y", to = r.y, duration = GLIDE.duration, easing = GLIDE.easing },
      { node = frame, property = "width", to = r.width, duration = GLIDE.duration, easing = GLIDE.easing },
      { node = frame, property = "height", to = r.height, duration = GLIDE.duration, easing = GLIDE.easing },
    } } }
  end)

  local dim = kit.surface { id = "window-menu-dim", anchors = { fill = true },
    color = function() return C.surface:alpha(opened:get() and .6 or 0) end,
    behavior = { color = { duration = theme.duration.normal, easing = theme.ease.standard } } }

  -- Shown while open, and for the fade after.
  local lingering = morf.signal("eva.window_menu.lingering", false)
  local fade
  morf.effect("material.window_menu.linger", function()
    local open = opened:get()
    if fade then fade:cancel() fade = nil end
    if open then lingering:set(true) return end
    fade = morf.time.timer(GLIDE.duration + 60, function() fade = nil lingering:set(false) end, false)
  end)
  local root = ui.Item { id = "window-menu-root", anchors = { fill = true },
    visible = function() return opened:get() or lingering:get() end,
    dim, frame, box }

  -- Opening, each card's buttons settle in after the card, one after another.
  local running = {}
  morf.effect("material.window_menu.open", function()
    local open = opened:get()
    for _, h in ipairs(running) do h:stop() end
    running = {}
    if not open then return end
    local order = { top = 0, left = 1, right = 2, bottom = 3 }
    local seen = {}
    for _, b in ipairs(boxes) do
      seen[b.key] = (seen[b.key] or 0) + 1
      local delay = 140 + order[b.key] * 40 + (seen[b.key] - 1) * 18
      running[#running + 1] = morf.animation.play { { parallel = {
        { node = b.area, property = "opacity", from = 0, to = 1, duration = 260, easing = "out_cubic", delay = delay },
        { node = b.area, property = "translate_y", from = 6, to = 0, duration = 320, easing = "out_cubic", delay = delay },
      } } }
    end
  end)

  return { node = root, box = box, shown = function(open) keys.focus = open end }
end

return V
