-- Every edge gesture, upright and on its side, at the logical sizes of the
-- devices eva runs on: a pull opens what hangs from that edge and a pull
-- back toward the edge shuts it; workspaces scroll along the edge the rail
-- is drawn on; two fingers up from the bottom bring the keyboard.

local test = morf.test

local SOURCE = [[
  local switches = {}
  local workspace = require("services").workspace
  local go = workspace.go
  workspace.go = function(id) switches[#switches + 1] = id go(id) end
  local volume_sets, osd = 0, require("osd")
  local set_volume = osd.set_volume
  osd.set_volume = function(...) volume_sets = volume_sets + 1 return set_volume(...) end
  require("init")
  morf.ipc.matrix_bar = function(side) require("bar").set_on(true) require("bar").set_side(side) end
  morf.ipc.matrix_state = function()
    local open = {}
    for _, d in ipairs(require("drawer").all) do open[d.name] = d.open:get() end
    return { open = open, switches = switches, keyboard = require("keyboard").active(),
      menu = require("menus").source:get(), sidebar_tab = require("sidebar").tab:get(),
      leftbar_tab = require("leftbar").panel.tab:get(), insets = require("bar").insets(),
      volume_sets = volume_sets, touch = require("models.touchscreens").attached() }
  end
]]

-- `touch`: the devices include a touchscreen.
local function load(width, height, touch)
  test.stub_run("task", { code = 0, stdout = "[]" })
  for _, program in ipairs { "systemctl", "loginctl" } do test.stub_run(program, { code = 0 }) end
  local devices = morf.env("EVA_INPUT_DEVICES")
  test.load("../shell/init.lua", { source = SOURCE, size = { width, height },
    env = { EVA_DRY_RUN = "1", EVA_WALLPAPER = "", EVA_FONT_FILE = "",
      EVA_INPUT_DEVICES = devices and touch and devices .. "-touch" or devices,
      LULE_A = "/nonexistent/lule", HOME = morf.env("XDG_CACHE_HOME") } })
  test.settle(2000)
end
local function state() return test.ipc("matrix_state") end

-- One finger from (x1, y1) to (x2, y2), a frame a step.
local function drag(x1, y1, x2, y2, steps)
  steps = steps or 14
  test.touch("down", 0, x1, y1) test.advance(16)
  for i = 1, steps do
    test.touch("move", 0, x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps) test.advance(16)
  end
  test.touch("up", 0, x2, y2) test.advance(800)
end

-- Two fingers up from `y` (`y2` for the second, which lands `lag` frames
-- after the first has started moving).
local function two_up(x, y, y2, lag)
  test.touch("down", 10, x, y) test.advance(16)
  for i = 1, lag do test.touch("move", 10, x, y - 6 * i) test.advance(16) end
  test.touch("down", 11, x + 70, y2) test.advance(16)
  for i = 1, 10 do
    test.touch("move", 10, x, y - 6 * lag - 16 * i) test.touch("move", 11, x + 70, y2 - 16 * i)
    test.advance(16)
  end
  test.touch("up", 10, x, y - 6 * lag - 160) test.touch("up", 11, x + 70, y2 - 160) test.advance(1000)
end

-- The middle of what drawer `name` shows.
local function middle(name)
  local r = test.get("drawer-" .. name)
  return r.x + r.width / 2, r.y + r.height / 2
end

local function pull_and_back(name, from, to, back)
  drag(from[1], from[2], to[1], to[2])
  test.truthy(state().open[name], name .. " opens")
  local x, y = middle(name)
  drag(x, y, x + back[1], y + back[2])
  test.falsy(state().open[name], name .. " shuts when pulled back")
end

-- Two fingers down across the keyboard put it away.
local function two_down_on_keys()
  local r = test.get("eva.osk.key.full.letters.q")
  test.touch("down", 10, r.x + 10, r.y + 10) test.touch("down", 11, r.x + 80, r.y + 10) test.advance(16)
  for i = 1, 8 do
    test.touch("move", 10, r.x + 10, r.y + 10 + 15 * i) test.touch("move", 11, r.x + 80, r.y + 10 + 15 * i)
    test.advance(16)
  end
  test.touch("up", 10, r.x + 10, r.y + 130) test.touch("up", 11, r.x + 80, r.y + 130) test.advance(1000)
end

local UPRIGHT, SIDEWAYS = { 620, 1380 }, { 1280, 720 }

test.describe("upright", function()
  local W, H = UPRIGHT[1], UPRIGHT[2]
  test.it("the top pulls quick settings down and back up", function()
    load(W, H)
    pull_and_back("sidebar", { W * .75, 2 }, { W * .75, 600 }, { 0, -420 })
  end)
  test.it("the bottom pulls the dashboard up and back down", function()
    load(W, H)
    pull_and_back("dashboard", { W / 2, H - 2 }, { W / 2, H - 700 }, { 0, 420 })
  end)
  test.it("a side pulls the launcher, and a swipe back toward it shuts it", function()
    load(W, H)
    drag(2, H / 2, 260, H / 2)
    test.truthy(state().open.launcher) test.eq(state().menu, "apps")
    local x, y = middle("launcher")
    drag(x + 150, y, x - 150, y, 6)
    test.falsy(state().open.launcher)
    drag(W - 2, H / 2, W - 260, H / 2)
    test.truthy(state().open.launcher) test.eq(state().menu, "web")
    x, y = middle("launcher")
    drag(x - 150, y, x + 150, y, 6)
    test.falsy(state().open.launcher)
  end)
  test.it("workspaces scroll along the bottom", function()
    load(W, H)
    drag(W - 60, H - 2, 60, H - 2)
    test.eq(#state().switches, 1)
  end)
  test.it("two fingers up from the bottom bring the keyboard", function()
    load(W, H)
    two_up(W / 2 - 40, H - 3, H - 3, 0)
    test.truthy(state().keyboard)
  end)
  test.it("the second finger may land above the edge strip, and late", function()
    load(W, H)
    two_up(W / 2 - 40, H - 3, H - 70, 3)
    test.truthy(state().keyboard)
  end)
end)

test.describe("sideways", function()
  local W, H = SIDEWAYS[1], SIDEWAYS[2]
  test.it("the top pulls the dashboard down and back up", function()
    load(W, H)
    pull_and_back("dashboard", { W / 2, 2 }, { W / 2, 420 }, { 0, -300 })
  end)
  test.it("the bottom pulls the bottom panel up and back down", function()
    load(W, H)
    pull_and_back("bottom", { W / 2, H - 2 }, { W / 2, H - 450 }, { 0, 300 })
  end)
  test.it("the left edge pulls the left panel and a pull back shuts it", function()
    load(W, H)
    pull_and_back("leftbar", { 2, H / 2 }, { 420, H / 2 }, { -300, 0 })
  end)
  test.it("the right edge pulls the right panel and a pull back shuts it", function()
    load(W, H)
    pull_and_back("sidebar", { W - 2, H / 2 }, { W - 420, H / 2 }, { 300, 0 })
  end)
  test.it("workspaces scroll along the left edge, where the rail is", function()
    load(W, H)
    drag(2, H - 120, 2, 120)
    test.eq(#state().switches, 1)
  end)
  test.it("and from across a side bar, not just its outer edge", function()
    for _, side in ipairs { "left", "right" } do
      load(W, H)
      test.ipc("matrix_bar", side) test.advance(400)
      local i = state().insets
      test.truthy(i[side] > 40, side .. " bar is wider than a finger")
      local x = side == "left" and i.left - 3 or W - i.right + 3
      drag(x, H - 120, x, 120)
      test.eq(#state().switches, 1, side)
    end
  end)
  test.it("and along the right edge", function()
    load(W, H)
    drag(W - 2, H - 120, W - 2, 120)
    test.eq(#state().switches, 1)
  end)
  test.it("two fingers up from the bottom bring the keyboard", function()
    load(W, H)
    two_up(W / 2 - 40, H - 3, H - 3, 0)
    test.truthy(state().keyboard)
  end)
  test.it("the second finger may land above the edge strip, and late", function()
    load(W, H)
    two_up(W / 2 - 40, H - 3, H - 70, 3)
    test.truthy(state().keyboard)
  end)
end)

for _, size in ipairs { UPRIGHT, SIDEWAYS } do
  local W, H = size[1], size[2]
  test.it(("at %dx%d two fingers down across the keyboard put it away"):format(W, H), function()
    load(W, H)
    two_up(W / 2 - 40, H - 3, H - 3, 0)
    test.truthy(state().keyboard)
    two_down_on_keys()
    test.falsy(state().keyboard)
  end)
end

test.it("sideways, a swipe away from a side panel's edge turns its tab", function()
  local W, H = SIDEWAYS[1], SIDEWAYS[2]
  load(W, H)
  drag(W - 2, H / 2, W - 420, H / 2)
  test.truthy(state().open.sidebar)
  local before = state().sidebar_tab
  local x, y = middle("sidebar")
  drag(x + 120, y, x - 120, y, 6)
  test.truthy(state().open.sidebar)
  test.eq(state().sidebar_tab, before + 1)
end)

for _, size in ipairs { UPRIGHT, SIDEWAYS } do
  local W, H = size[1], size[2]
  test.it(("at %dx%d a press on a sheet's empty part is not one outside it"):format(W, H), function()
    load(W, H)
    for _, name in ipairs { "launcher", "session" } do
      test.ipc(name, "open") test.advance(800)
      test.truthy(state().open[name], name .. " opens")
      local r = test.get("drawer-" .. name)
      test.touch("down", 0, r.x + 6, r.y + r.height - 6) test.touch("up", 0, r.x + 6, r.y + r.height - 6)
      test.advance(600)
      test.truthy(state().open[name], name .. " stays open")
      test.ipc("close") test.advance(800)
    end
  end)
  test.it(("at %dx%d the session menu is pulled shut toward its edge"):format(W, H), function()
    load(W, H)
    test.ipc("session", "open") test.advance(800)
    local x, y = middle("session")
    drag(x - 100, y, x + 260, y)
    test.falsy(state().open.session)
  end)
end

test.it("a touchscreen is told from the input devices", function()
  load(UPRIGHT[1], UPRIGHT[2]) test.falsy(state().touch)
  load(UPRIGHT[1], UPRIGHT[2], true) test.truthy(state().touch)
end)
test.it("on a touchscreen the dashboard pulls shut from its tab row, upright and on its side", function()
  for _, case in ipairs {
    { UPRIGHT, { UPRIGHT[1] / 2, UPRIGHT[2] - 2 }, { UPRIGHT[1] / 2, UPRIGHT[2] - 700 }, 420 },
    { SIDEWAYS, { SIDEWAYS[1] / 2, 2 }, { SIDEWAYS[1] / 2, 420 }, -300 },
  } do
    load(case[1][1], case[1][2], true)
    drag(case[2][1], case[2][2], case[3][1], case[3][2])
    test.truthy(state().open.dashboard)
    local tab = test.get("dashboard-tab-battery")
    local x, y = tab.x + tab.width / 2, tab.y + tab.height / 2
    drag(x, y, x, y + case[4])
    test.falsy(state().open.dashboard, "pulled from the tab row")
  end
end)
-- A slider keeps only the drags along it (engines after 0.4.1 tell the
-- runtime its axis): a pull across one shuts the panel holding it, and
-- leaves the slider where it was.
local function across_it(name, fn)
  if morf.satisfies(">0.4.1") then test.it(name, fn) else test.skip(name, "the engine has no drag_axis") end
end
across_it("upright, quick settings pull shut from a slider, which stays put", function()
  local W, H = UPRIGHT[1], UPRIGHT[2]
  load(W, H)
  drag(W * .75, 2, W * .75, 600)
  test.truthy(state().open.sidebar)
  local slider = test.get("utilities-volume")
  local x, y = slider.x + slider.width * .8, slider.y + slider.height / 2
  drag(x, y, x, y - 420)
  test.falsy(state().open.sidebar, "pulled from the slider")
  test.eq(state().volume_sets, 0)
end)

-- How it feels: a quick short flick toward its edge shuts a panel, and the
-- same distance pushed slowly and held before letting go leaves it open.
local function flick(x, y, dx, dy)
  test.touch("down", 0, x, y) test.advance(16)
  for i = 1, 4 do test.touch("move", 0, x + dx * i / 4, y + dy * i / 4) test.advance(16) end
  test.touch("up", 0, x + dx, y + dy) test.advance(800)
end
local function nudge(x, y, dx, dy)
  test.touch("down", 0, x, y) test.advance(16)
  for i = 1, 14 do test.touch("move", 0, x + dx * i / 14, y + dy * i / 14) test.advance(16) end
  test.advance(150) test.touch("up", 0, x + dx, y + dy) test.advance(800)
end
local PANELS = {
  { "sideways right panel", SIDEWAYS, "sidebar", { SIDEWAYS[1] - 2, 360, SIDEWAYS[1] - 420, 360 }, { 70, 0 } },
  { "sideways left panel", SIDEWAYS, "leftbar", { 2, 360, 420, 360 }, { -70, 0 } },
  { "sideways bottom panel", SIDEWAYS, "bottom", { 640, 718, 640, 270 }, { 0, 70 } },
  { "sideways dashboard", SIDEWAYS, "dashboard", { 640, 2, 640, 420 }, { 0, -70 } },
  { "upright quick settings", UPRIGHT, "sidebar", { 465, 2, 465, 600 }, { 0, -70 } },
  { "upright dashboard", UPRIGHT, "dashboard", { 310, 1378, 310, 680 }, { 0, 70 } },
}
for _, p in ipairs(PANELS) do
  test.it(p[1] .. " flicks shut, and a slow nudge leaves it open", function()
    load(p[2][1], p[2][2])
    local o, d = p[4], p[5]
    drag(o[1], o[2], o[3], o[4])
    test.truthy(state().open[p[3]], "opens")
    local x, y = middle(p[3])
    nudge(x, y, d[1], d[2])
    test.truthy(state().open[p[3]], "a slow nudge leaves it open")
    x, y = middle(p[3])
    flick(x, y, d[1], d[2])
    test.falsy(state().open[p[3]], "a flick shuts it")
  end)
end
for _, size in ipairs { UPRIGHT, SIDEWAYS } do
  test.it(("at %dx%d the session menu and the launcher flick shut"):format(size[1], size[2]), function()
    load(size[1], size[2])
    test.ipc("session", "open") test.advance(800)
    local x, y = middle("session")
    nudge(x, y, 70, 0)
    test.truthy(state().open.session, "a slow nudge leaves it open")
    flick(x, y, 70, 0)
    test.falsy(state().open.session, "a flick shuts the session menu")
    test.ipc("launcher", "open") test.advance(800)
    x, y = middle("launcher")
    local away = state().menu == "web" and 70 or -70
    nudge(x, y, away / 2, 0)
    test.truthy(state().open.launcher, "a slow nudge leaves it open")
    flick(x, y, away, 0)
    test.falsy(state().open.launcher, "a flick shuts the launcher")
  end)
end
