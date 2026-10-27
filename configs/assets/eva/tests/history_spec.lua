-- Rolling graph history, with a fake machine and virtual time. No GPU,
-- D-Bus or real device sampling is needed.
local test = morf.test

local HOST = [[
  local sysinfo = require("lib.services.sysinfo")
  local root = morf.env("XDG_CACHE_HOME") .. "/history-machine"
  local function write(path, text) assert(morf.fs.write(root .. path, text)) end
  local function inputs(n)
    write("/proc/stat", ("cpu %d 0 0 %d 0 0 0 0\ncpu0 %d 0 0 %d 0 0 0 0\n")
      :format(n * 10, n * 10, n * 10, n * 10))
    write("/proc/meminfo", ("MemTotal: 1000 kB\nMemAvailable: %d kB\nSwapTotal: 1000 kB\nSwapFree: %d kB\n")
      :format(1000 - n * 10, 1000 - n * 10))
    write("/sys/class/power_supply/BAT0/type", "Battery")
    write("/sys/class/power_supply/BAT0/capacity", tostring(n))
    write("/sys/class/power_supply/BAT0/energy_now", tostring(n * 1000000))
    write("/sys/class/power_supply/BAT0/energy_full", "100000000")
    write("/sys/class/power_supply/BAT0/power_now", tostring(n * 1000000))
    write("/sys/class/power_supply/BAT0/voltage_now", "12000000")
    write("/sys/class/power_supply/BAT0/temp", "300")
  end
  inputs(0)
  sysinfo.configure { root = root, blocking = true }
  -- Keep what each chart the integration test reads is drawn from (the
  -- series its line is evaluated over), not just the collector behind it.
  local kit = require("kit")
  local chart, charts = kit.chart, {}
  kit.chart = function(spec)
    if spec.id == "battery-graph-charge" or spec.id == "performance-cpu-graph" then charts[spec.id] = spec end
    return chart(spec)
  end
  local state = require("dashboard_state")
  morf.ipc.graph_points = function(id) return #charts[id].first() end
  morf.ipc.inputs = inputs
  morf.ipc.opened = function(on, tab)
    if on ~= nil then state.opened:set(on) end
    if tab then state.tab:set(tab) end
    return state.opened:get()
  end
  morf.ipc.samples = function(name) return sysinfo.sources[name].samples end
  morf.ipc.running = function(name) return sysinfo.sources[name]:running() end
  morf.ipc.history = function(name) return morf.json.encode(sysinfo.history(name)) end
  morf.ipc.limit = function() return sysinfo.history_size end
]]

local function load(full_shell)
  -- Most cases need only the collector; the integration case builds the UI.
  local source = full_shell and HOST:gsub('local state = require%("dashboard_state"%)',
    'require("init")\n  local state = require("dashboard_state")') or HOST
  test.load("../shell/dashboard_state.lua", { source = source, env = {
    EVA_DRY_RUN = "1", EVA_WALLPAPER = "", EVA_FONT_FILE = "",
    LULE_A = "/nonexistent/lule", HOME = morf.env("XDG_CACHE_HOME"),
  } })
end
-- A phone whose display power the test switches, as phone-screen reports it.
local PHONE = [[
  local file = morf.env("XDG_RUNTIME_DIR") .. "/phone-screen-" .. morf.env("HYPRLAND_INSTANCE_SIGNATURE") .. ".status"
  local status, changed = "on", nil
  local read, watch = morf.fs.read, morf.fs.watch
  morf.fs.read = function(path, ...)
    if path == "/fixture-phone-screen.json" then return '{"command":"/fixture/phone-screen"}' end
    if path == file then return status .. "\n" end
    return read(path, ...)
  end
  morf.fs.watch = function(path, callback, ...)
    if path == file then changed = callback return {} end
    return watch(path, callback, ...)
  end
  morf.ipc.power = function(value) status = value changed() end
]]
local function load_phone()
  test.load("../shell/dashboard_state.lua", { source = PHONE .. HOST, env = {
    EVA_DRY_RUN = "0", EVA_WALLPAPER = "", EVA_FONT_FILE = "",
    LULE_A = "/nonexistent/lule", HOME = morf.env("XDG_CACHE_HOME"),
    MORF_PHONE_SCREEN_CONFIG = "/fixture-phone-screen.json",
    XDG_RUNTIME_DIR = "/tmp", HYPRLAND_INSTANCE_SIGNATURE = "fixture",
  } })
end
local function history(name) return morf.json.decode(test.ipc("history", name)) end
local function points(id)
  return test.ipc("graph_points", id)
end

test.describe("eva graph history", function()
  test.it("collects while the complete shell's dashboard is hidden", function()
    load(true)
    for n = 1, 6 do
      test.ipc("inputs", n)
      test.advance(3000)
    end
    for _, name in ipairs { "cpu", "memory", "battery" } do
      test.truthy(test.ipc("samples", name) >= 4, name .. " stopped in the full shell")
    end
    test.truthy(#history("bat:BAT0:percent") >= 4)
    test.ipc("dashboard", "open")
    test.advance(800)
    test.click("dashboard-tab-battery")
    test.advance(800)
    test.eq(points("battery-graph-charge"), #history("bat:BAT0:percent"),
      "opening the battery graph lost the samples collected while hidden")
    test.click("dashboard-tab-perf")
    test.advance(800)
    test.eq(points("performance-cpu-graph"), #history("cpu"),
      "opening performance lost the samples collected while hidden")
    test.ipc("dashboard", "close")
    test.advance(800)
    local before = test.ipc("samples", "battery")
    for n = 7, 10 do
      test.ipc("inputs", n)
      test.advance(3000)
    end
    test.truthy(test.ipc("samples", "battery") >= before + 4,
      "closing the real drawer stopped battery collection")
    test.ipc("dashboard", "open")
    test.advance(800)
    test.eq(points("performance-cpu-graph"), #history("cpu"))
    test.click("dashboard-tab-battery")
    test.advance(800)
    test.eq(points("battery-graph-charge"), #history("bat:BAT0:percent"),
      "reopening omitted the time spent hidden")
    test.eq(#test.logs("error"), 0)
  end)

  test.it("samples before opening a tab and overwrites the oldest values at the graph limit", function()
    load()
    test.eq(test.ipc("opened"), false)
    -- Never read any history until more than a full window has passed.
    -- A source without pinning stops after two unread samples.
    for n = 1, 65 do
      test.ipc("inputs", n)
      test.advance(3000)
    end
    local limit = test.ipc("limit")
    test.eq(limit, 60)
    for _, name in ipairs { "cpu", "memory", "drives", "network", "gpu", "fans", "battery" } do
      test.eq(test.ipc("running", name), true, name .. " stopped with the dashboard shut")
    end
    for _, name in ipairs { "processes", "disks", "temperatures", "system", "backlight" } do
      test.eq(test.ipc("running", name), false, name .. " should stay demand-driven")
    end
    for _, name in ipairs { "memory", "swap", "bat:BAT0:percent", "bat:BAT0:power" } do
      local values = history(name)
      test.eq(#values, limit, name)
      for i, value in ipairs(values) do test.near(value, i + 5, 0.001, name) end
    end
    test.eq(#history("cpu"), limit)
    test.eq(#history("core0"), limit)
    test.eq(#history("bat:BAT0:voltage"), limit)
    test.eq(#history("bat:BAT0:temperature"), limit)
    test.eq(#test.logs("error"), 0)
  end)

  test.it("stops collecting while a phone display is blanked and resumes on wake", function()
    local graphs = { "cpu", "memory", "drives", "network", "gpu", "fans", "battery" }
    load_phone()
    for n = 1, 3 do
      test.ipc("inputs", n)
      test.advance(3000)
    end
    for _, name in ipairs(graphs) do test.eq(test.ipc("running", name), true, name) end
    test.ipc("power", "off")
    for n = 4, 8 do
      test.ipc("inputs", n)
      test.advance(3000)
    end
    local asleep = {}
    for _, name in ipairs(graphs) do
      test.eq(test.ipc("running", name), false, name .. " kept sampling a blanked phone")
      asleep[name] = test.ipc("samples", name)
    end
    test.advance(30000)
    for _, name in ipairs(graphs) do test.eq(test.ipc("samples", name), asleep[name], name) end
    test.ipc("power", "on")
    for n = 9, 11 do
      test.ipc("inputs", n)
      test.advance(3000)
    end
    for _, name in ipairs(graphs) do
      test.eq(test.ipc("running", name), true, name .. " did not resume on wake")
    end
    -- The fake machine has data for these; the rest sample nothing here.
    for _, name in ipairs { "cpu", "memory", "battery" } do
      test.truthy(test.ipc("samples", name) > asleep[name], name .. " took no samples after waking")
    end
    test.eq(#test.logs("error"), 0)
  end)

  test.it("keeps history across tab switches and closing, and resets with a new runtime", function()
    load()
    test.advance(12000)
    local before = test.ipc("samples", "battery")
    test.truthy(before >= 4, "no battery history before first opening")
    test.ipc("opened", true, 4)
    test.eq(#history("bat:BAT0:percent"), before)
    test.ipc("opened", true, 3)
    test.ipc("opened", false)
    test.advance(12000)
    local after = test.ipc("samples", "battery")
    test.truthy(after >= before + 4, "closing stopped collection")
    test.ipc("opened", true, 4)
    test.eq(#history("bat:BAT0:percent"), after)
    load()
    test.truthy(#history("bat:BAT0:percent") < before, "history survived a restart")
  end)
end)
