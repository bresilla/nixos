-- Older user themes do not yet attach Caelestia's phone gestures. Use
-- Morf's plugin hook to add them while keeping the user's theme in place.
-- attach() is idempotent when a newer theme also calls it itself.
local ok, frame = pcall(require, "themes.frame_host")
if not ok or type(frame) ~= "function" then return end
frame = require("phone_repair.frame_host")
-- Install replacements lazily, before theme/controller initialization. This
-- keeps the gesture driver and motion cancellation in step on older dotfiles.
local load = require
local replacements = {
  bar = "phone_repair.bar",
  keyboard = "phone_repair.keyboard_controller",
  ["themes.keyboard"] = "phone_repair.shared_keyboard",
  responsive = "phone_repair.responsive",
  drawer = "phone_repair.drawer",
  ["themes.layouts.views.keyboard"] = "phone_repair.keyboard",
  ["lib.kit.control"] = "phone_repair.control",
  ["lib.kit.scroll"] = "phone_repair.scroll",
  ["lib.util.osk"] = "phone_repair.osk",
  ["themes.material.motion"] = "phone_repair.material_motion",
  ["themes.tsugumori.motion"] = "phone_repair.tsugumori_motion",
  ["themes.layouts.tabbed"] = "phone_repair.tabbed",
  ["themes.layouts.views.dashboard"] = "phone_repair.dashboard",
  ["themes.layouts.views.dashboard_terminal"] = "phone_repair.dashboard_terminal",
  ["themes.layouts.views.side_panel"] = "phone_repair.side_panel",
}
require = function(name)
  local replacement = replacements[name]
  if not replacement then return load(name) end
  local value = load(replacement)
  package.loaded[name] = value
  return value
end
package.loaded["themes.frame_host"] = function(...)
  local root = frame(...)
  require("phone_gestures").attach(root)
  return root
end
