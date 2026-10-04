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
local units = {M = 1024^2, G = 1024^3, T = 1024^4}
local function size_bytes(value)
  local count, unit = value:match("^(%d+)([MGT])$")
  return count and tonumber(count) * units[unit] or nil
end
local function size(prompt, default, optional)
  return input(prompt .. (optional and " (0 to omit, or e.g. 32G)" or " (e.g. 1G)"), default, function(value)
    local bytes = size_bytes(value)
    return (optional and value == "0") or (bytes ~= nil and bytes >= 16 * 1024^2),
      "Use a whole number followed by M, G or T, at least 16M" .. (optional and ", or 0 to omit" or "")
  end)
end
local function mounted(device)
  for _, mount in ipairs(device.mountpoints or {}) do
    if type(mount) == "string" and mount ~= "" then return true end
  end
  for _, child in ipairs(device.children or {}) do if mounted(child) then return true end end
  return false
end
local function disks()
  local value, message = oslo.json.decode(run({"lsblk", "--json", "--bytes", "--paths", "--output",
    "NAME,TYPE,SIZE,MODEL,MOUNTPOINTS"}, true))
  if not value then die(message) end
  local result = {}
  for _, disk in ipairs(value.blockdevices) do
    if disk.type == "disk" and tonumber(disk.size) > 0 and not mounted(disk) then
      table.insert(result, disk)
    end
  end
  return result
end
local function btrfs(mountpoint, label)
  return '{ type = "btrfs"; extraArgs = [ "-f" "-L" ' .. quoted(label) .. ' ]; subvolumes.'
    .. quoted("/@" .. label) .. ' = { mountpoint = ' .. quoted(mountpoint)
    .. '; mountOptions = [ "noatime" "compress=zstd:3" "ssd" ]; }; }'
end
local function generate_layout()
  local available, items = disks(), {}
  if #available == 0 then die("No unmounted disks are available; the live USB is excluded") end
  for _, disk in ipairs(available) do
    table.insert(items, string.format("%s — %.1f GiB — %s", disk.name, tonumber(disk.size) / 1024^3, disk.model or ""))
  end
  local selected = choose("Disk to erase (mounted disks are excluded)", items)
  local disk
  for index, item in ipairs(items) do if item == selected then disk = available[index] end end
  local kind = choose("Disk layout", {"Btrfs subvolumes", "LVM with Btrfs volumes", "Ext4"})
  local efi = size("EFI partition size", "1G", false)
  local volumes, used = {}, size_bytes(efi) + 8 * 1024^2
  if kind == "LVM with Btrfs volumes" then
    for _, spec in ipairs({
      {"root", "/", "32G"}, {"home", "/home", "32G"}, {"nix", "/nix", "160G"},
      {"docs", "/doc", "128G"}, {"pkg", "/pkg", "32G"},
    }) do
      local capacity = size(spec[2] .. " volume size", spec[3], spec[1] ~= "root")
      if capacity ~= "0" then
        table.insert(volumes, {name = spec[1], mountpoint = spec[2], size = capacity})
        used = used + size_bytes(capacity)
      end
    end
  end
  local swap = size("Swap size", "0", true)
  if swap ~= "0" then used = used + size_bytes(swap) end
  if used + 1024^3 > tonumber(disk.size) then
    die("The requested layout does not fit on the disk; leave at least 1 GiB free for the root filesystem and metadata")
  end
  local lines = {
    "{", "  disko.devices = {", "    disk.system = {", '      type = "disk";',
    "      device = " .. quoted(disk.name) .. ";", '      content = { type = "gpt"; partitions = {',
    '        ESP = { priority = 1; size = ' .. quoted(efi) .. '; type = "EF00";',
    '          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; }; };',
  }
  if kind == "LVM with Btrfs volumes" then
    table.insert(lines, '        lvm = { size = "100%"; content = { type = "lvm_pv"; vg = "pool"; }; };')
    table.insert(lines, "      }; };\n    };")
    table.insert(lines, '    lvm_vg.pool = { type = "lvm_vg"; lvs = {')
    for _, volume in ipairs(volumes) do
      table.insert(lines, "      " .. volume.name .. " = { size = " .. quoted(volume.size)
        .. "; content = " .. btrfs(volume.mountpoint, volume.name) .. "; };")
    end
    if swap ~= "0" then
      table.insert(lines, '      swap = { size = ' .. quoted(swap) .. '; content = { type = "swap"; resumeDevice = true; }; };')
    end
    table.insert(lines, "    }; };")
  else
    if swap ~= "0" then
      table.insert(lines, '        swap = { priority = 2; size = ' .. quoted(swap)
        .. '; content = { type = "swap"; resumeDevice = true; }; };')
    end
    local root
    if kind == "Ext4" then
      root = '{ type = "filesystem"; format = "ext4"; mountpoint = "/"; }'
    else
      root = '{ type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = {'
      for _, spec in ipairs({{"root", "/"}, {"home", "/home"}, {"nix", "/nix"}}) do
        root = root .. quoted("/@" .. spec[1]) .. ' = { mountpoint = ' .. quoted(spec[2])
          .. '; mountOptions = [ "noatime" "compress=zstd:3" "ssd" ]; };'
      end
      root = root .. "}; }"
    end
    table.insert(lines, '        root = { priority = 3; size = "100%"; content = ' .. root .. "; };")
    table.insert(lines, "      }; };\n    };")
  end
  table.insert(lines, "  };\n}\n")
  local layout = table.concat(lines, "\n")
  print("\nDisko layout preview:\n" .. layout)
  if ui.confirm{question = "Save this disk layout?", default = false} ~= true then
    die("Cancelled; no disks were changed")
  end
  local path = input("Save Disko file as", oslo.sys.pwd() .. "/disko.nix", function(value)
    return not oslo.fs.exists(value), "That path exists; choose a new filename or use the existing file"
  end)
  write(path, layout)
  print("Saved machine-specific layout: " .. path)
  return path
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
      layout = generate_layout()
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
  run({"cp", "--", layout, repo .. "/disko.nix"})
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
