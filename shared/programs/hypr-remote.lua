-- hypr-remote start|stop|status: the on-demand remote Hyprland session.
-- remote-desktop.nix runs this as root through sudo and passes its settings in the environment.
local function setting(name)
  return oslo.env.get(name) or error(name .. " is not set; run this through hypr-remote", 0)
end

local user = setting("HYPR_REMOTE_USER")
local vt = setting("HYPR_REMOTE_VT")
local port = setting("HYPR_REMOTE_PORT")
local password_file = setting("HYPR_REMOTE_PASSWORD_FILE")
local chvt = setting("HYPR_REMOTE_CHVT")

local function die(message)
  io.stderr:write("hypr-remote: " .. message .. "\n")
  os.exit(1)
end

local function run(argv)
  local r = oslo.run(argv)
  if not r.ok then die(argv[1] .. " failed (" .. r.status .. ")") end
end

-- The RDP password lives only on this machine; it is set on the first start.
local function ensure_password()
  local current = oslo.fs.read(password_file)
  if current and current ~= "" then return end
  local password = oslo.ui.input{ prompt = "RDP password for " .. user .. ": ", password = true, required = true }
  if not password then die("cancelled; no password was set") end
  local again = oslo.ui.input{ prompt = "Repeat it: ", password = true, required = true }
  if again ~= password then die("the passwords differ; nothing was set") end
  run{ "install", "-d", "-o", user, "-m", "700", (password_file:match("^(.*)/[^/]+$")) }
  run{ "install", "-o", user, "-m", "600", "/dev/null", password_file }
  local ok, err = oslo.fs.write(password_file, password)
  if not ok then die(err) end
end

local action = arg[1]
if action == "start" then
  ensure_password()
  run{ chvt, vt }
  run{ "systemctl", "start", "hypr-remote.service" }
  print("Remote Hyprland session started on tty" .. vt .. "; RDP listens on port " .. port .. ".")
elseif action == "stop" then
  run{ "systemctl", "stop", "hypr-remote.service" }
  run{ chvt, "1" }
elseif action == "status" then
  os.exit(oslo.run{ "systemctl", "status", "--no-pager", "hypr-remote.service" }.status)
else
  io.stderr:write("usage: hypr-remote start|stop|status\n")
  os.exit(2)
end
