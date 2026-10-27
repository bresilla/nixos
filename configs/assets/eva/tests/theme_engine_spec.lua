-- A theme made for a newer engine than this one (`morf` in its manifest)
-- gives way to Material at start, and is refused when asked for, the shell
-- saying why both times. An engine from before morf.satisfies cannot be
-- asked, and every theme is shown as before.

local test = morf.test

-- Tsugumori, as if it had been written for a morf from the future.
local SHELL = [[
  require("themes.tsugumori.manifest").morf = ">=99"
  return require("init")
]]

local function load(style)
  for _, program in ipairs { "systemctl", "loginctl" } do test.stub_run(program, { code = 0 }) end
  test.stub_run("task", { code = 0, stdout = "[]" })
  test.load("../shell/init.lua", {
    source = SHELL,
    size = { 1920, 1080 },
    env = { EVA_STYLE = style, EVA_DRY_RUN = "1", EVA_WALLPAPER = "", EVA_FONT_FILE = "",
      LULE_A = "/nonexistent/lule", HOME = morf.env("XDG_CACHE_HOME") },
  })
  test.settle(2000)
end

test.describe("a theme for a newer engine", function()
  test.it("gives way to Material at start, and the shell says why", function()
    if not morf.satisfies then return end
    load("tsugumori")
    test.eq(test.ipc("appearance").theme, "material")
    test.truthy(test.find { text = "Theme unavailable" })
  end)

  test.it("is refused when asked for, with the reason", function()
    if not morf.satisfies then return end
    load("material")
    test.eq(test.ipc("appearance", "tsugumori"), false)
    local state = test.ipc("appearance")
    test.eq(state.theme, "material")
    test.truthy(tostring(state.message):find("Tsugumori needs morf >=99", 1, true))
  end)
end)
