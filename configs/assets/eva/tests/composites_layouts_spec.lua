-- The layout composites (themes/kit/composites/: file_chooser) worked by
-- the pointer and by the keyboard, in each theme.
--
--     morf test --no-dbus tests/composites_layouts_spec.lua

local test = morf.test

local SOURCE = [[
  local ui = require("morf.ui")
  local kit = require("kit")
  local composites = require("themes.kit.composites")
  morf.surface.height = 1000
  local got = {}
  local function keep(name) return function(...)
    local parts = {}
    for _, v in ipairs({ ... }) do
      if type(v) ~= "table" then parts[#parts + 1] = tostring(v)
      elseif #v > 0 then parts[#parts + 1] = table.concat(v, ",") end
    end
    got[name] = table.concat(parts, " ")
  end end

  -- A folder to choose from.
  local dir = (morf.env("XDG_RUNTIME_DIR") or "/tmp") .. "/morf-layouts-" .. tostring(morf.process_id)
  pcall(morf.fs.remove, dir, { recursive = true })
  for _, d in ipairs { dir, dir .. "/alpha", dir .. "/alpha/deep", dir .. "/beta" } do morf.fs.mkdir(d) end
  for _, f in ipairs { "photo.png", "notes.txt", "zeta.jpg", "alpha/inner.txt", "alpha/shot.png" } do
    morf.fs.write(dir .. "/" .. f, "x")
  end

  local width = morf.state { w = 640 }
  local fc_node, fc = composites.file_chooser { id = "fc", width = function() return width.w end, height = 320,
    root = dir, mode = "open", on_accepted = keep("file"), on_cancelled = keep("cancelled"),
    places = { { label = "Fixture", path = dir, icon = "folder" }, { label = "Alpha", path = dir .. "/alpha" } },
    filters = { { name = "All files" }, { name = "Images", patterns = { "png", "jpg" } } } }
  kit.card { width = 1800, height = 1000, ui.Item { x = 560, y = 660, fc_node } }
  morf.ipc.got = function(k) return got[k] or "" end
  morf.ipc.fc = function() return fc.path():sub(#dir + 1) .. "|" .. table.concat(fc.entries(), ",") end
  morf.ipc.fc_shell = function() return tostring(fc.shell.t.collapsed) .. "|" .. tostring(fc.shell.t.sidebar_open) end
  morf.ipc.narrow = function(w) width.w = tonumber(w) end
  morf.ipc.dir = function() return dir end
  morf.ipc.cleanup = function() morf.fs.remove(dir, { recursive = true }) end
]]

local function load(style)
  test.load("../shell/init.lua", { size = { 1800, 1000 }, env = { EVA_STYLE = style }, source = SOURCE })
  test.settle(800)
end
local function got(name) return test.ipc("got", name) end
local function shot(name) if morf.env("MORF_THEME_SNAPSHOTS") == "1" then test.snapshot(name .. ".png") end end
-- The node of that id that shows (a kept page's twin may be hidden).
local function shown(id)
  for _, node in ipairs(test.find_all(id)) do if node.visible then return node end end
  test.truthy(false, "no visible " .. id)
end
local function centre(node) return node.x + node.width / 2, node.y + node.height / 2 end
local function clean()
  test.ipc("cleanup")
  test.eq(#test.logs("error"), 0, "errors were logged")
  test.eq(#test.logs("warn"), 0, "warnings were logged")
end

for _, style in ipairs { "material", "tsugumori" } do
  test.it(style .. " file chooser walks folders, filters, picks a file and collapses its places", function()
    load(style)
    test.eq(test.ipc("fc"), "|alpha,beta,notes.txt,photo.png,zeta.jpg")
    -- Into a folder: a double press, then Return on one inside.
    local alpha = shown("fc-entry-alpha")
    test.click(alpha.x + 60, alpha.y + 10) test.settle(50) test.click(alpha.x + 60, alpha.y + 10) test.settle(500)
    test.eq(test.ipc("fc"), "/alpha|deep,inner.txt,shot.png")
    test.key("Home") test.key("Return") test.settle(500)
    test.eq(test.ipc("fc"), "/alpha/deep|")
    -- Back, then up by the breadcrumbs and the up press.
    test.click("fc-back") test.settle(500)
    test.eq(test.ipc("fc"), "/alpha|deep,inner.txt,shot.png")
    test.click("fc-crumb-1") test.settle(500)
    test.eq(test.ipc("fc"), "|alpha,beta,notes.txt,photo.png,zeta.jpg")
    test.click("fc-place-2") test.settle(500)
    test.eq(test.ipc("fc"), "/alpha|deep,inner.txt,shot.png")
    test.click("fc-up") test.settle(500)
    test.eq(test.ipc("fc"), "|alpha,beta,notes.txt,photo.png,zeta.jpg")
    -- The filter.
    test.click("fc-filter") test.settle(300)
    test.click("fc-filter-item-2") test.settle(300)
    test.eq(test.ipc("fc"), "|alpha,beta,photo.png,zeta.jpg")
    -- A file: chosen by a press, accepted by Open.
    test.click(shown("fc-entry-photo.png")) test.settle(100)
    test.click("fc-accept") test.settle(100)
    test.eq(got("file"), test.ipc("dir") .. "/photo.png")
    -- The path field goes where it is told.
    test.click("fc-path-field") test.key("a", "ctrl") test.type(test.ipc("dir") .. "/beta") test.key("Return")
    test.settle(500)
    test.eq(test.ipc("fc"), "/beta|")
    shot(style .. "-layouts-files")
    -- Narrow: the places become a drawer, F9 opens it, Escape shuts it.
    test.eq(test.ipc("fc_shell"), "false|true")
    test.ipc("narrow", 420) test.settle(500)
    test.eq(test.ipc("fc_shell"), "true|false")
    test.falsy(test.get("fc-place-1").visible and test.get("fc-place-1").x >= test.get("fc").x)
    test.click("fc-sidebar-toggle") test.settle(400)
    test.eq(test.ipc("fc_shell"), "true|true")
    shot(style .. "-layouts-files-narrow")
    test.click("fc-place-2") test.settle(500)
    test.eq(test.ipc("fc"), "/alpha|deep,shot.png")
    test.key("F9") test.settle(400)
    test.eq(test.ipc("fc_shell"), "true|false")
    clean()
  end)
end
