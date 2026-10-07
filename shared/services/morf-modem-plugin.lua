-- Retain the live ModemManager observer in existing Caelestia checkouts.
-- Load replacements at the usual point in startup: settings_model also
-- initializes notification surfaces, which must wait for the shell's setup.
local load = require
local replacements = {
  services = "modem_repair.services",
  settings_model = "modem_repair.settings_model",
  bar_model = "modem_repair.bar_model",
}
require = function(name)
  local replacement = replacements[name]
  if not replacement then return load(name) end
  local value = load(replacement)
  package.loaded[name] = value
  return value
end
