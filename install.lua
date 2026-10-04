-- Run by install.sh with the normal Oslo release and terminal stdin.
local ui = oslo.ui
local function die(message) error(message, 0) end
local function run(argv, capture)
  argv.capture = capture or false
  local result = oslo.run(argv)
  if not result.ok then
    die(argv[1] .. " failed (" .. result.status .. "): " .. (result.err or "see terminal output"))
  end
  return result.out
end
local function write(path, contents)
  local ok, message = oslo.fs.write(path, contents)
  if not ok then die(message) end
end
local function choose(header, items)
  local answer = ui.choose{header = header, items = items}
  if not answer then die("Cancelled; no disks were changed") end
  print(header .. ": " .. answer)
  return answer
end
local function input(prompt, default, validate)
  while true do
    local answer = ui.input{prompt = prompt .. ": ", default = default, required = true}
    if answer == nil then die("Cancelled; no disks were changed") end
    local ok, message = validate(answer)
    if ok then print(prompt .. ": " .. answer); return answer end
    print(message)
    default = answer
  end
end
local function quoted(text)
  -- Nix strings also interpolate ${...}, unlike JSON strings.
  return '"' .. text:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('%${', '\\${') .. '"'
end
local function main()
  local repo = arg[1]
  if not repo or not oslo.fs.exists(repo .. "/flake.nix") then die("Launch this through install.sh") end
  if run({"uname", "-m"}, true) ~= "x86_64" then die("These configurations target x86_64") end
  if not oslo.fs.exists("/sys/firmware/efi") then die("Boot the live environment in UEFI mode") end
  if oslo.run{"mountpoint", "-q", "/mnt"}.ok then die("Unmount /mnt before starting a new installation") end
  local role = arg[2] or choose("Configuration", {"laptop", "server"})
  if role ~= "laptop" and role ~= "server" then die("Configuration must be laptop or server") end
  local layout = arg[3]
  if not layout then
    local action = choose("Machine-specific Disko configuration", {"Use an existing Disko file", "Create a Disko file"})
    if action == "Create a Disko file" then
      layout = input("Save Disko file as", oslo.sys.pwd() .. "/disko.nix", function(value)
        return value ~= "", "Choose an output filename"
      end)
      run({"bash", repo .. "/discio.sh", layout})
    else
      layout = ui.file{start = oslo.sys.pwd()}
      if not layout then die("Cancelled; no disks were changed") end
    end
  end
  if not oslo.run{"test", "-f", layout}.ok then die("Disko file not found: " .. layout) end
  local username = input("Username", nil, function(value)
    return #value <= 32 and value:match("^[a-z_][a-z0-9_-]*$") and value ~= "root",
      "Use up to 32 lowercase letters, digits, underscores or hyphens; start with a letter or underscore; root is reserved"
  end)
  local as_root = run({"id", "-u"}, true) ~= "0"
  if as_root then run({"sudo", "-v"}) end
  local function root(argv)
    if as_root then table.insert(argv, 1, "sudo") end
    return run(argv)
  end
  if layout ~= repo .. "/disko.nix" then run({"cp", "--", layout, repo .. "/disko.nix"}) end
  write(repo .. "/user.nix", "{ bresilla.user.name = " .. quoted(username) .. "; }\n")
  local flake = "path:" .. repo .. "#nixosConfigurations." .. role .. ".config"
  local function nix(command, ...)
    local argv = {"nix", "--extra-experimental-features", "nix-command flakes", command}
    for _, value in ipairs({...}) do table.insert(argv, value) end
    return run(argv, true)
  end
  local paths = nix("eval", "--raw", flake .. ".disko.devices.disk", "--apply",
    'disks: builtins.concatStringsSep "\n" (map (disk: disk.device) (builtins.attrValues disks))')
  local targets = {}
  for disk in paths:gmatch("[^\n]+") do
    if not disk:match("^/dev/") or not oslo.run{"test", "-b", disk}.ok then
      die(disk .. " is not a block device under /dev")
    end
    if run({"lsblk", "-dnro", "TYPE", disk}, true) ~= "disk" then die("Select a whole disk, not a partition: " .. disk) end
    if run({"lsblk", "-nr", "-o", "MOUNTPOINT", disk}, true):match("%S") then
      die(disk .. " has mounted partitions or active swap; unmount them first")
    end
    run({"lsblk", "-d", "-o", "NAME,SIZE,MODEL", disk})
    table.insert(targets, disk)
  end
  if #targets == 0 then die("Your Disko file must define at least one disk") end
  print("Validating #" .. role .. " and preparing Disko before disk erasure...")
  nix("eval", "--raw", flake .. ".system.build.toplevel.drvPath")
  local script = nix("build", "--no-link", "--print-out-paths", flake .. ".system.build.diskoScript")
  local expected = table.concat(targets, " ")
  print("\nInstall #" .. role .. " for " .. username .. " using " .. layout)
  print("ALL DATA ON THESE DISKS WILL BE ERASED: " .. expected)
  local confirmation = ui.input{prompt = "Type '" .. expected .. "' to erase and install: ", required = true}
  if confirmation ~= expected then die("Cancelled; no disks were changed") end
  -- Recheck immediately before erasure; a disk might have been mounted during the prompts.
  if oslo.run{"mountpoint", "-q", "/mnt"}.ok then die("Unmount /mnt before installing") end
  for _, disk in ipairs(targets) do
    if run({"lsblk", "-nr", "-o", "MOUNTPOINT", disk}, true):match("%S") then
      die(disk .. " has mounted partitions or active swap; unmount them first")
    end
  end
  root({script})
  root({"mkdir", "-p", "/mnt/etc/nixos"})
  root({"cp", "-a", "--no-preserve=ownership", repo .. "/.", "/mnt/etc/nixos/"})
  root({"nixos-install", "--root", "/mnt", "--flake", "path:/mnt/etc/nixos#" .. role})
  print("Set the password for " .. username .. ":")
  root({"nixos-enter", "--root", "/mnt", "--", "passwd", username})
  print("Installed #" .. role .. ". Configuration: /etc/nixos. Reboot when ready.")
end
local ok, message = pcall(main)
if not ok then
  io.stderr:write("error: " .. tostring(message) .. "\n")
  os.exit(1)
end
