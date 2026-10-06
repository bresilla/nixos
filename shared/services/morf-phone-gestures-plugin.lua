-- Older user themes do not yet attach Caelestia's phone gestures. Use
-- Morf's plugin hook to add them while keeping the user's theme in place.
-- attach() is idempotent when a newer theme also calls it itself.
local ok, frame = pcall(require, "themes.frame_host")
if not ok or type(frame) ~= "function" then return end
package.loaded["themes.layouts.tabbed"] = require("phone_repair.tabbed")
package.loaded["themes.layouts.views.dashboard"] = require("phone_repair.dashboard")
package.loaded["themes.layouts.views.side_panel"] = require("phone_repair.side_panel")
package.loaded["themes.frame_host"] = function(...)
  local root = frame(...)
  require("phone_gestures").attach(root)
  return root
end
