-- A BlueZ pairing agent (org.bluez.Agent1) while the Bluetooth page is
-- open: a device that shows a code to confirm, asks for a PIN or a passkey,
-- or asks to be allowed, is answered from the page. Only BlueZ's own calls
-- are taken.
local morf = require("morf")
local M = {}
local PATH = "/org/eva/BluetoothAgent"
local AGENT, MANAGER = "org.bluez.Agent1", "org.bluez.AgentManager1"
local REJECTED, CANCELED = "org.bluez.Error.Rejected", "org.bluez.Error.Canceled"

--- What a device asks now, or nil: `kind` ("confirm", "authorize", "pin",
--- "passkey" or "display"), `device` (its path), and `code` where there is one.
M.request = morf.signal("eva.bluetooth.agent.request", nil)
local service, owner, waiting

local function settle(ok, value, error_name)
  local call = waiting
  waiting = nil
  M.request:set(nil)
  if not (call and service) then return end
  pcall(function()
    if ok then service:reply(call, value) else service:reply_error(call, error_name or REJECTED, "refused") end
  end)
end

local function ask(call, kind, device, code)
  if waiting then settle(false, nil, CANCELED) end
  waiting = call.id
  M.request:set({ kind = kind, device = device, code = code })
end

local function handle(call)
  if call.interface ~= AGENT or (owner and call.sender ~= owner) then
    service:reply_error(call.id, "org.freedesktop.DBus.Error.AccessDenied", "not BlueZ")
    return
  end
  local a, m = call.arguments or {}, call.member
  if m == "RequestConfirmation" then ask(call, "confirm", a[1], ("%06d"):format(tonumber(a[2]) or 0))
  elseif m == "RequestAuthorization" then ask(call, "authorize", a[1])
  elseif m == "RequestPinCode" then ask(call, "pin", a[1])
  elseif m == "RequestPasskey" then ask(call, "passkey", a[1])
  elseif m == "DisplayPinCode" or m == "DisplayPasskey" then
    local code = m == "DisplayPasskey" and ("%06d"):format(tonumber(a[2]) or 0) or tostring(a[2] or "")
    M.request:set({ kind = "display", device = a[1], code = code })
    service:reply(call.id, nil)
  elseif m == "AuthorizeService" then service:reply(call.id, nil)
  elseif m == "Cancel" then
    if waiting then settle(false, nil, CANCELED) else M.request:set(nil) end
    service:reply(call.id, nil)
  elseif m == "Release" then
    M.request:set(nil)
    service:reply(call.id, nil)
  else
    service:reply_error(call.id, "org.freedesktop.DBus.Error.UnknownMethod", "no method " .. tostring(m))
  end
end

--- Registers the agent as BlueZ's default; true once it is.
function M.start()
  if service then return true end
  local ok, s, outcome = pcall(morf.dbus.serve, "system", "", PATH, false)
  if not ok or outcome ~= "owned" then return false end
  service = s
  service:on_call(handle)
  local registered = pcall(function()
    owner = service:call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
      { "org.bluez" })
    if type(owner) == "table" then owner = owner[1] end
    local path = { signature = "o", value = PATH }
    service:call("org.bluez", "/org/bluez", MANAGER, "RegisterAgent", { path, "KeyboardDisplay" })
    service:call("org.bluez", "/org/bluez", MANAGER, "RequestDefaultAgent", { path })
  end)
  if not registered then
    pcall(function() service:close() end)
    service, owner = nil, nil
    return false
  end
  return true
end

function M.stop()
  if not service then return end
  settle(false, nil, CANCELED)
  M.request:set(nil)
  pcall(function()
    service:call("org.bluez", "/org/bluez", MANAGER, "UnregisterAgent", { { signature = "o", value = PATH } })
  end)
  pcall(function() service:close() end)
  service, owner = nil, nil
end

--- Answers what is asked: true or false for a confirmation or an
--- authorization, the PIN or the passkey typed; nil refuses.
function M.answer(value)
  local r = M.request:get()
  if not r then return end
  if r.kind == "display" then M.request:set(nil) return end
  if value == nil or value == false then return settle(false) end
  if r.kind == "pin" then return settle(true, tostring(value)) end
  if r.kind == "passkey" then
    local n = tonumber(value)
    if not n then return settle(false) end
    return settle(true, { signature = "u", value = math.floor(n) })
  end
  settle(true, nil)
end

return M
