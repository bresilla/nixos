-- Eva's composites: widgets built from archetypes, each looking the way its
-- parts' skins make it look.
--
--     local composites = require("themes.kit.composites")
--     local node, combo = composites.combo_box { items = { "One", "Two" }, current = 1 }
--
-- Each is a module `themes.kit.composites.<name>` returning its
-- constructor, `make(spec) -> node, handle`; this table finds them by name,
-- loading each the first time it is asked for.
local M = {}

local NAMES = { calendar = true, combo_box = true, input_group = true, colour_picker = true, font_picker = true,
  file_chooser = true, date_picker = true }

setmetatable(M, { __index = function(t, name)
  if not NAMES[name] then return nil end
  local made = require("themes.kit.composites." .. name)
  local make = type(made) == "table" and made.make or made
  rawset(t, name, make)
  return make
end })

--- Whether a composite named `name` exists.
function M.has(name) return NAMES[name] == true end

return M
