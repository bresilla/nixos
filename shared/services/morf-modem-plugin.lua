-- Supply mobile settings and the live modem observer to existing checkouts.
-- Load replacements at the usual point in startup: settings_model also
-- initializes notification surfaces, which must wait for the shell's setup.
local load = require
local replacements = {
  services = "modem_repair.services",
  settings_model = "modem_repair.settings_model",
  bar_model = "modem_repair.bar_model",
  utilities = "modem_repair.utilities",
  connectivity = "modem_repair.connectivity",
  mobile_model = "modem_repair.mobile_model",
  ["themes.layouts.views.connectivity"] = "modem_repair.connectivity_view",
  ["lib.services.modem"] = "modem_repair.modem_service",
  ["lib.services.networkmanager"] = "modem_repair.networkmanager_service",
}
require = function(name)
  local replacement = replacements[name]
  if not replacement then return load(name) end
  local value = load(replacement)
  package.loaded[name] = value
  return value
end
