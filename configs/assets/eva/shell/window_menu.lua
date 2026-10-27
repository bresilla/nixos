-- The window menu: a cross of cards over the focused window -- the window
-- itself in the middle, and on each side a card of buttons for one kind of
-- thing to do to it, each a single press. Opened over IPC (`window_menu
-- toggle`), which a compositor key calls; everything it does is a
-- Hyprland dispatcher sent to that one window by its address.
--
-- Keys: the arrows move between the buttons, across cards too, and Enter
-- or Space presses one; 1 to 9 and 0 send the window to that workspace;
-- Escape shuts it. EVA_DRY_RUN=1 logs what would be dispatched instead.
local morf = require("morf")
local services = require("services")
local hyprland = services.hyprland
local M = {}

M.opened = morf.signal("eva.window_menu.opened", false)
M.address = morf.signal("eva.window_menu.address", "")
-- The button the keys are on ("" for none): "<card>:<button>".
M.focus = morf.signal("eva.window_menu.focus", "")
-- Whether moving the window to a workspace goes there with it.
M.follow = require("themes.session").keep("eva.window_menu.follow", true)

local function dry_run()
  local v = morf.env and morf.env("EVA_DRY_RUN")
  return v ~= nil and v ~= "" and v ~= "0"
end

local function client(address)
  if address == "" then return nil end
  local model = hyprland.state.clients
  for i = 1, model:len() do
    local row = model:get(i)
    if row.address == address then return row end
  end
end
--- The window the menu is about, as the compositor has it now.
function M.window() return client(M.address:get()) end

-- ------------------------------------------------------------- dispatch --

local lua_config
local function flavour(done)
  if lua_config ~= nil then return done(lua_config) end
  local ok, config = pcall(require, "lib.compositor.hyprland_config")
  if not ok then lua_config = false return done(false) end
  config.flavour(function(kind) lua_config = kind == "lua" done(lua_config) end)
end

local function quoted(value) return ("%q"):format(tostring(value)) end
local function fields(t)
  local out = {}
  for k, v in pairs(t) do out[#out + 1] = k .. " = " .. (type(v) == "string" and quoted(v) or tostring(v)) end
  table.sort(out)
  return "{ " .. table.concat(out, ", ") .. " }"
end

--- Runs `steps` on the window: each `{ lua = { "window.pin", {...} },
--- conf = { dispatcher, argument } }`, the Lua form on a Lua-configured
--- Hyprland and the classic one elsewhere.
local function run(steps)
  local address = M.address:get()
  if address == "" then return false end
  local selector = "address:" .. address
  if dry_run() then
    local names = {}
    for _, s in ipairs(steps) do names[#names + 1] = s.lua[1] end
    morf.log("info", "eva: window menu (dry run): " .. table.concat(names, ", ") .. " on " .. address)
    return true
  end
  flavour(function(lua)
    if lua then
      local chunk = {}
      for _, s in ipairs(steps) do
        if s.global and #chunk == 0 then chunk[1] = ("hl.dispatch(hl.dsp.focus({ window = %s }))"):format(quoted(selector)) end
      end
      for _, s in ipairs(steps) do
        local args = s.lua[2]
        if type(args) == "string" then args = quoted(args)
        else
          local t = {}
          for k, v in pairs(args or {}) do t[k] = v end
          if not s.global then t.window = selector end
          args = fields(t)
        end
        chunk[#chunk + 1] = ("hl.dispatch(hl.dsp.%s(%s))"):format(s.lua[1], args)
      end
      hyprland.eval(table.concat(chunk, " "), function(reply, err)
        if err or (reply and not reply:match("^%s*ok%s*$")) then
          morf.log("warn", "eva: window menu: " .. tostring(err or reply))
        end
      end)
    else
      -- Classic dispatchers mostly act on the focused window: focus it first.
      local queue = { { "focuswindow", "$W" } }
      for _, s in ipairs(steps) do queue[#queue + 1] = s.conf end
      local function step(i)
        local s = queue[i]
        if not s then return end
        local arg = s[2] and (s[2]:gsub("%$W", selector)) or nil
        hyprland.dispatch(s[1], arg, function() step(i + 1) end)
      end
      step(1)
    end
  end)
  return true
end

local function S(lua, conf) return { lua = lua, conf = conf } end
local function toggle(name, conf) return S({ "window." .. name, { action = "toggle" } }, conf) end
local function G(lua, conf) return { global = true, lua = lua, conf = conf } end

-- --------------------------------------------------------------- cards --

local function yes(v) return v == true end
local function monitor_of(w)
  local model = hyprland.state.monitors
  for i = 1, model:len() do
    local m = model:get(i)
    if m.id == w.monitor then return m end
  end
end
--- A floating window `fraction` of its screen, centred there.
local function sized(fraction)
  local w = M.window() or {}
  local m = monitor_of(w) or {}
  local x = math.floor((m.width or 1920) / (m.scale or 1) * fraction)
  local y = math.floor((m.height or 1080) / (m.scale or 1) * fraction)
  return {
    S({ "window.float", { action = "on" } }, { "setfloating", "$W" }),
    S({ "window.resize", { x = x, y = y } }, { "resizewindowpixel", ("exact %d %d,$W"):format(x, y) }),
    S({ "window.center", {} }, { "centerwindow", nil }),
  }
end
local function to_workspace(id)
  local follow = M.follow:get()
  return { S({ "window.move", { workspace = tostring(id), follow = follow } },
    { follow and "movetoworkspace" or "movetoworkspacesilent", id .. ",$W" }) }
end

--- Each card: `key` (where it sits), `number`, `title`, and its buttons --
--- `key`, `label`, `on` (lit: what the window is now), `primary`, `span`
--- (grid cells), `stay` (the menu stays open after it), and `steps` (sent to
--- the compositor) or `press` (done here).
M.CARDS = {
  { key = "center", number = "00", title = "Window", buttons = function() return {} end },
  { key = "top", number = "01", title = "Layout", buttons = function()
    local w = M.window() or {}
    local fs = w.fullscreen or 0
    return {
      { key = "float", label = w.floating and "Tile" or "Float", on = yes(w.floating), stay = true,
        steps = { toggle("float", { "togglefloating", "$W" }) } },
      { key = "fullscreen", label = "Fullscreen", on = fs == 2, stay = true,
        steps = { S({ "window.fullscreen", { mode = "fullscreen" } }, { "fullscreen", "0" }) } },
      { key = "maximize", label = "Maximize", on = fs == 1, stay = true,
        steps = { S({ "window.fullscreen", { mode = "maximized" } }, { "fullscreen", "1" }) } },
      { key = "pin", label = "Pin", on = yes(w.pinned), stay = true, steps = { toggle("pin", { "pin", "$W" }) } },
      { key = "center", label = "Center", stay = true, steps = { S({ "window.center", {} }, { "centerwindow", nil }) } },
      { key = "front", label = "To front", stay = true,
        steps = { S({ "window.bring_to_top", {} }, { "bringactivetotop", nil }) } },
      { key = "half", label = "50%", stay = true, steps = sized(0.5) },
      { key = "two_thirds", label = "66%", stay = true, steps = sized(0.66) },
      { key = "most", label = "85%", stay = true, steps = sized(0.85) },
    }
  end },
  { key = "left", number = "02", title = "Workspace", buttons = function()
    local w = M.window() or {}
    local out = {}
    for id = 1, 10 do
      out[#out + 1] = { key = "ws" .. id, label = tostring(id), on = w.workspace == id, steps = to_workspace(id) }
    end
    out[#out + 1] = { key = "follow", label = "Follow", on = M.follow:get(), stay = true, span = 2,
      press = function() M.follow:set(not M.follow:get()) end }
    out[#out + 1] = { key = "stash", label = "Stash away", span = 3,
      steps = { S({ "window.move", { workspace = "special:eva", follow = false } }, { "movetoworkspacesilent", "special:eva,$W" }) } }
    return out
  end },
  { key = "right", number = "03", title = "Screen", buttons = function()
    local w = M.window() or {}
    local out = {}
    local model = hyprland.state.monitors
    for i = 1, math.min(model:len(), 4) do
      local m = model:get(i)
      out[#out + 1] = { key = "mon:" .. m.name, label = m.name, on = w.monitor == m.id,
        steps = { S({ "window.move", { monitor = m.name } }, { "movewindow", "mon:" .. m.name }) } }
    end
    if #out % 2 == 1 then out[#out].span = 2 end
    out[#out + 1] = { key = "group", label = "Group", stay = true, steps = { G({ "group.toggle", {} }, { "togglegroup", nil }) } }
    out[#out + 1] = { key = "lock", label = "Lock group", stay = true,
      steps = { G({ "group.lock_active", { action = "toggle" } }, { "lockactivegroup", "toggle" }) } }
    return out
  end },
  { key = "bottom", number = "04", title = "Close", buttons = function()
    return {
      { key = "close", label = "Close", primary = true, steps = { S({ "window.close", {} }, { "closewindow", "$W" }) } },
      { key = "kill", label = "Force quit", steps = { S({ "window.kill", {} }, { "killwindow", "$W" }) } },
    }
  end },
}
local BY_KEY = {}
for _, c in ipairs(M.CARDS) do BY_KEY[c.key] = c end
function M.card(key) return BY_KEY[key] end
function M.buttons(key) local c = BY_KEY[key] return c and c.buttons() or {} end

--- The cards' readings: a line and two corner words.
function M.summary(key)
  local w = M.window()
  if not w then return { "No window", "", "" } end
  if key == "center" then return { w.class ~= "" and w.class or "Window", w.title or "", "" } end
  if key == "top" then
    local state = w.fullscreen == 2 and "Fullscreen" or w.fullscreen == 1 and "Maximized" or w.floating and "Floating" or "Tiled"
    return { ("%s · %d × %d"):format(state, w.width, w.height), "", "" }
  elseif key == "left" then
    local n, model = 0, hyprland.state.clients
    for i = 1, model:len() do if model:get(i).workspace == w.workspace then n = n + 1 end end
    return { ("On %s · %d window%s"):format(w.workspace_name ~= "" and w.workspace_name or tostring(w.workspace),
      n, n == 1 and "" or "s"), "", "" }
  elseif key == "right" then
    local m = monitor_of(w) or {}
    return { m.name and ("%s · %dx%d"):format(m.name, m.width, m.height) or "Screen", "", "" }
  elseif key == "bottom" then
    return { ("%s · PID %d"):format(w.class ~= "" and w.class or "window", w.pid or 0), "", "" }
  end
  return { "", "", "" }
end

-- -------------------------------------------------------------- presses --

local function find(id)
  local card, key = tostring(id or ""):match("^([^:]+):(.+)$")
  if not card then return nil end
  for _, b in ipairs(M.buttons(card)) do if b.key == key then return b end end
end

--- Presses button `id` ("<card>:<button>").
function M.press(id)
  local b = find(id)
  if not b then return false end
  M.focus:set(id)
  local ok = true
  if b.press then b.press() elseif b.steps then ok = run(b.steps) end
  if ok and not b.stay then M.close() end
  return ok
end

-- The buttons' boxes, as the view lays them out: `{ id, x, y, width, height }`.
local boxes = function() return {} end
function M.attach(fn) boxes = fn end

--- The nearest button from the focused one (the middle card's centre when
--- none) in direction `dx, dy`.
local function step(dx, dy)
  local list = boxes()
  local from
  for _, b in ipairs(list) do if b.id == M.focus:get() then from = b end end
  local fx, fy
  if from then fx, fy = from.x + from.width / 2, from.y + from.height / 2
  else local c = list.center or { x = 0, y = 0, width = 0, height = 0 } fx, fy = c.x + c.width / 2, c.y + c.height / 2 end
  local best, score
  for _, b in ipairs(list) do
    local bx, by = b.x + b.width / 2 - fx, b.y + b.height / 2 - fy
    local along, across = bx * dx + by * dy, math.abs(bx * dy - by * dx)
    if b.id ~= M.focus:get() and along > 4 then
      local s = along + across * 2.5
      if not score or s < score then best, score = b, s end
    end
  end
  if best then M.focus:set(best.id) end
end

local DIRECTIONS = { Up = { 0, -1 }, Down = { 0, 1 }, Left = { -1, 0 }, Right = { 1, 0 } }
function M.key(_, _, _, _, name)
  if name == "Escape" then M.close() return true end
  if name == "Return" or name == "KP_Enter" or name == "space" then
    if M.focus:get() ~= "" then M.press(M.focus:get()) end
    return true
  end
  local d = DIRECTIONS[name]
  if d then step(d[1], d[2]) return true end
  if name and name:match("^%d$") then
    local id = tonumber(name) == 0 and 10 or tonumber(name)
    M.press("left:ws" .. id)
    return true
  end
  return true
end

-- ---------------------------------------------------------------- open --

--- Whether this screen holds the focused window (the focused screen when
--- the compositor does not say where it is).
function M.here()
  local active = hyprland.state.active_window
  local w = client(active and active.address or "")
  local screen = morf.screens and morf.screens[1] and morf.screens[1].name or ""
  local m = w and monitor_of(w)
  if m then return m.name == screen end
  return services.here()
end

--- Opens over the focused window: true when it did, false when there is
--- none, nothing while it asks the compositor which window that is.
local FOLD_MS, closed_at, waiting = 280, -1e9, nil
function M.open()
  local function show(address, folded)
    if not client(address) then return false end
    if waiting then waiting:cancel() waiting = nil end
    -- Over another window: the menu folds away where it was first, then
    -- opens there.
    local other = address ~= M.address:get()
    if other and M.opened:get() then M.close() end
    local left = FOLD_MS - (morf.time.now_ms() - closed_at)
    if other and left > 0 and not folded then
      waiting = morf.time.timer(left, function() waiting = nil show(address, true) end, false)
      return true
    end
    M.address:set(address)
    M.focus:set("")
    M.opened:set(true)
    return true
  end
  local active = hyprland.state.active_window
  if show(active and active.address or "") then return true end
  -- Hyprland reports no window while a layer (this menu) has the keyboard,
  -- and does not always report the window again once the layer lets go:
  -- ask it which window has the focus now.
  local asked = hyprland.json("j/activewindow", function(reply)
    local address = type(reply) == "table" and tostring(reply.address or "") or ""
    if address ~= "" and address:sub(1, 2) ~= "0x" then address = "0x" .. address end
    show(address)
  end)
  if asked then return nil end
  return false
end
function M.close()
  if waiting then waiting:cancel() waiting = nil end
  if M.opened:get() then closed_at = morf.time.now_ms() end
  M.opened:set(false)
end
function M.toggle() if M.opened:get() then M.close() return false end return M.open() end

-- The window gone (closed, killed), the menu goes with it.
morf.effect("eva.window_menu.gone", function()
  if M.opened:get() and M.window() == nil then M.close() end
end)

-- How the compositor draws windows: their corner rounding and border width.
M.style = morf.state { rounding = 0, border = 0 }
local function read_style()
  if not hyprland.options then return end
  hyprland.options({ "decoration:rounding", "general:border_size" }, function(options)
    if not options then return end
    M.style.rounding = math.max(0, tonumber((options["decoration:rounding"] or {}).int) or 0)
    M.style.border = math.max(0, tonumber((options["general:border_size"] or {}).int) or 0)
  end)
end
morf.effect("eva.window_menu.style", function() if M.opened:get() then morf.time.timer(1, read_style, false) end end)

local function ratio()
  local s = morf.screens and morf.screens[1] or {}
  return (s.width and s.logical_width and s.logical_width > 0) and s.width / s.logical_width or 1
end
--- The window's corner radius and border, in the shell's pixels: none
--- while it is fullscreen or maximized.
function M.rounding()
  local w = M.window()
  if not w or (w.fullscreen or 0) ~= 0 then return 0 end
  return M.style.rounding * ratio()
end
function M.border()
  local w = M.window()
  if not w or (w.fullscreen or 0) ~= 0 then return 0 end
  return M.style.border * ratio()
end

--- This screen's size, and the window's box on it, in the shell's pixels
--- (the compositor's are logical ones, from its layout's origin).
function M.screen()
  local s = morf.screens and morf.screens[1] or {}
  return s.width or 1920, s.height or 1080
end
function M.rect()
  local w = M.window()
  if not w then return nil end
  local s = morf.screens and morf.screens[1] or {}
  local m = monitor_of(w) or {}
  local ratio = (s.width and s.logical_width and s.logical_width > 0) and s.width / s.logical_width or 1
  return { x = (w.x - (m.x or 0)) * ratio, y = (w.y - (m.y or 0)) * ratio,
    width = w.width * ratio, height = w.height * ratio }
end

local view = require("themes").view("window_menu").build(M)
M.node = view.node
-- A press anywhere off the cards shuts it.
require("themes.kit.popup").track(view.box, { open = function() return M.opened:get() end,
  close_policy = "outside", modal = true, on_close = function() M.close() end })
morf.effect("eva.window_menu.shown", function() view.shown(M.opened:get()) end)

return M
