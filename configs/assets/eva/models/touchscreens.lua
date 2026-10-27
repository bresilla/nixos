-- Whether a touchscreen is attached, read like models.keyboards: from
-- EVA_INPUT_DEVICES in place of /proc/bus/input/devices when that is set.
local morf = require("morf")

local M = {}

-- A touchscreen is a direct input device: INPUT_PROP_DIRECT, bit 1 of PROP.
function M.attached()
  local path = morf.env and morf.env("EVA_INPUT_DEVICES")
  if path == false or path == "" then path = nil end
  local ok, text = pcall(morf.fs.read, path or "/proc/bus/input/devices")
  if not ok or type(text) ~= "string" then return false end
  for prop in text:gmatch("B: PROP=(%x+)") do
    if math.floor(tonumber(prop, 16) / 2) % 2 == 1 then return true end
  end
  return false
end

return M
