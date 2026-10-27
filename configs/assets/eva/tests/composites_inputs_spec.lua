-- The input composites (themes/kit/composites: combo_box, input_group) at
-- work in each eva theme: each opens and chooses by the pointer and by the
-- keys, hands what was chosen to its callback, closes on Escape and gives
-- focus back to what opened it.
--
--     morf test --no-dbus tests/composites_inputs_spec.lua

local test = morf.test

local SOURCE = [[
  local ui = require("morf.ui")
  local kit = require("kit")
  local composites = require("themes.kit.composites")
  morf.surface.height = 900
  local log = {}
  local function note(s) log[#log + 1] = s end
  local handles, nodes = {}, {}

  nodes.combo, handles.combo = composites.combo_box { id = "combo", x = 20, y = 20, width = 220,
    items = { "Small", "Medium", "Large" }, current = 1,
    on_changed = function(i, item) note("combo:" .. i .. ":" .. item) end }
  nodes.search, handles.search = composites.combo_box { id = "fruit", x = 260, y = 20, width = 220, search = true,
    items = { "Apple", "Banana", "Cherry", "Date" }, current = 2,
    on_changed = function(i, item) note("fruit:" .. i .. ":" .. item) end }
  nodes.group = composites.input_group { id = "url", x = 500, y = 400, width = 360, prefix = "https://",
    suffix = { id = "url-go", label = "Go", on_clicked = function() note("go") end },
    on_accepted = function(text) note("url:" .. text) end }
  local root = ui.Item { width = 1500, height = 900 }
  for _, node in pairs(nodes) do ui.reparent(node, root) end

  morf.ipc.log = function() local s = table.concat(log, ","); log = {}; return s end
  morf.ipc.open = function(name) return handles[name].is_open() end
  morf.ipc.focus = function(name)
    local node = name == "fruit" and handles.search.input or nodes[name]
    morf.focus.set(node, true)
  end
  morf.ipc.fruit_text = function() return handles.search.input.text end
  morf.ipc.fruit_shown = function() return table.concat(handles.search.filtered(), ",") end
]]

local function load(style)
  test.load("../shell/init.lua", { size = { 1500, 900 }, env = { EVA_STYLE = style }, source = SOURCE })
  test.settle(400)
end

local function focused()
  for _, node in ipairs(test.nodes()) do if node.focused then return node.id end end
end

local function centre(id)
  local n = test.get(id)
  return n.x + n.width / 2, n.y + n.height / 2
end

for _, style in ipairs { "material", "tsugumori" } do
  test.it(style .. ": a combo box opens and picks by the pointer and by the keys", function()
    load(style)
    test.click("combo") test.settle(60)
    test.truthy(test.ipc("open", "combo"), "a press did not open it")
    local field, item = test.get("combo"), test.get("combo-item-1")
    test.truthy(item.y >= field.y + field.height, "the list is not under its field")
    test.click("combo-item-3") test.settle(60)
    test.eq(test.ipc("log"), "combo:3:Large")
    test.falsy(test.ipc("open", "combo"))
    test.truthy(test.find { text = "Large", visible = true })
    -- The keys: Space opens on the current item, Up moves, Return picks.
    test.ipc("focus", "combo") test.settle(30)
    test.key("space") test.settle(60)
    test.truthy(test.ipc("open", "combo"))
    test.eq(focused(), "combo-list")
    test.key("Up") test.key("Return") test.settle(60)
    test.eq(test.ipc("log"), "combo:2:Medium")
    test.falsy(test.ipc("open", "combo"))
    test.eq(focused(), "combo")
    -- Alt+Down opens; Escape closes and leaves the current item.
    test.key("Down", "alt") test.settle(60)
    test.truthy(test.ipc("open", "combo"))
    test.key("Down") test.key("Escape") test.settle(60)
    test.falsy(test.ipc("open", "combo"))
    test.eq(test.ipc("log"), "")
    test.eq(focused(), "combo")
    test.eq(#test.logs("error"), 0)
  end)

  test.it(style .. ": a searchable combo filters as it is typed into", function()
    load(style)
    test.click("fruit") test.settle(30) test.advance(20)
    test.type("ch") test.settle(60)
    test.truthy(test.ipc("open", "search"), "typing did not open the list")
    test.eq(test.ipc("fruit_shown"), "3")
    test.key("Return") test.settle(60)
    test.eq(test.ipc("log"), "fruit:3:Cherry")
    test.eq(test.ipc("fruit_text"), "Cherry")
    test.falsy(test.ipc("open", "search"))
    -- Down opens the whole list on the current item; Down again, Return.
    test.key("Down") test.settle(60)
    test.truthy(test.ipc("open", "search"))
    test.key("Down") test.key("Return") test.settle(60)
    test.eq(test.ipc("log"), "fruit:4:Date")
    -- A press on a row picks it; Escape closes and puts the text back.
    test.key("Down") test.settle(60)
    local x, y = centre("fruit-list")
    local list = test.get("fruit-list")
    test.click(x, list.y + 36 * 0.5) test.settle(60)
    test.eq(test.ipc("log"), "fruit:1:Apple")
    test.type("zz") test.settle(30)
    test.key("Escape") test.settle(60)
    test.falsy(test.ipc("open", "search"))
    test.eq(test.ipc("fruit_text"), "Apple")
    test.eq(focused(), "fruit")
    test.eq(#test.logs("error"), 0)
  end)

  test.it(style .. ": an input group's button and field", function()
    load(style)
    test.click("url-go") test.settle(30)
    test.eq(test.ipc("log"), "go")
    test.click("url") test.settle(30)
    test.type("morf.dev") test.key("Return") test.settle(30)
    test.eq(test.ipc("log"), "url:morf.dev")
  end)
end
