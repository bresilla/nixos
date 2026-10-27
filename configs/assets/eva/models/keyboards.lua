-- Whether a real keyboard is attached (lib.services.keyboards), read from
-- EVA_INPUT_DEVICES in place of /proc/bus/input/devices when that is set.
-- The specs set it, so what they see does not depend on the machine they
-- run on.
local morf = require("morf")

local M = {}

function M.attached()
  local path = morf.env and morf.env("EVA_INPUT_DEVICES")
  if path == false or path == "" then path = nil end
  return require("lib.services.keyboards").attached(path)
end

return M
