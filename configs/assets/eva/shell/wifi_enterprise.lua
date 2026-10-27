-- Joining an 802.1X network (eduroam, a company's) with a user name and a
-- password: a NetworkManager profile for PEAP with MSCHAPv2 inside, sent
-- over the system bus so the password is on no command line.
local dbus_client = require("lib.services.dbus")
local M = {}
local client
local NM, ROOT = "org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager"

--- Joins `row` (an access point row of `net`) as `identity`; `done(path, err)`
--- hears the active connection, or why not.
function M.join(net, row, identity, password, done)
  local device
  for _, d in ipairs((net.snapshot and net.snapshot() or {}).devices or {}) do
    if d.type == "wifi" and ((row.device or "") == "" or d.interface == row.device) then device = d break end
  end
  if not device then return nil, "no wifi device" end
  client = client or dbus_client.new({ bus = "system" })
  local typed = dbus_client.typed
  local settings = {
    connection = { id = row.ssid, type = "802-11-wireless" },
    ["802-11-wireless"] = { ssid = typed("ay", row.ssid) },
    ["802-11-wireless-security"] = { ["key-mgmt"] = "wpa-eap" },
    ["802-1x"] = { eap = typed("as", { "peap" }), ["phase2-auth"] = "mschapv2",
      identity = identity, password = password },
  }
  return client.call_async(NM, ROOT, NM, "AddAndActivateConnection",
    { typed("a{sa{sv}}", settings), dbus_client.o(device.path), dbus_client.o(row.path or "/") }, 30000,
    function(reply, err)
      if net.refresh then pcall(net.refresh) end
      if type(reply) == "table" then return done(reply[2]) end
      done(nil, err or "no active connection")
    end)
end

return M
