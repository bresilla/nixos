-- Run by install.sh with the normal Oslo release and terminal stdin.
local ui = oslo.ui
local function die(message) error(message, 0) end
local function run(argv, capture)
  -- Keep diagnostics and build progress visible while reading stdout results.
  argv.capture_out = capture or false
  local result = oslo.run(argv)
  if not result.ok then
    die(argv[1] .. " failed (" .. result.status .. "): " .. (result.err ~= "" and result.err or "see terminal output"))
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
  local roles = {"laptop", "server", "phone", "iot"}
  local function valid_role(role)
    for _, name in ipairs(roles) do if role == name then return true end end
    return false
  end
  local function nix(command, ...)
    local argv = {"nix", "--extra-experimental-features", "nix-command flakes", "--accept-flake-config", command}
    for _, value in ipairs({...}) do table.insert(argv, value) end
    return run(argv, true)
  end
  local function root(argv, capture)
    if run({"id", "-u"}, true) ~= "0" then table.insert(argv, 1, "sudo") end
    return run(argv, capture)
  end
  local function refresh_inputs()
    print("Refreshing flake inputs to their latest upstream revisions...")
    run({"nix", "--extra-experimental-features", "nix-command flakes", "--accept-flake-config",
      "flake", "update", "--refresh", "--flake", "path:" .. repo})
  end
  local function copy_if_present(name)
    if oslo.fs.exists("/etc/nixos/" .. name) then
      run({"cp", "-a", "--", "/etc/nixos/" .. name, repo .. "/" .. name})
    end
  end
  local update = choose("Action", {"Update this machine", "Install"}) == "Update this machine"
  local role, device, info
  local function select_dotfiles()
    local suggestion = "https://github.com/bresilla/dot.git"
    if update and oslo.fs.exists("/etc/nixos/dotfiles.nix") then
      suggestion = nix("eval", "--raw", "--file", "/etc/nixos/dotfiles.nix", "--apply", "settings: settings.url")
    end
    print("Dotfiles must be a public HTTPS Git repository with nix/home.nix and a .config directory.")
    print("The Home Manager module must evaluate for the selected user and link to their ~/.dot checkout.")
    local work = repo .. "/.dotfiles-input"
    run({"mkdir", "-p", work .. "/config/oslo"})
    write(work .. "/config/oslo/init.lua", "dofile(" .. string.format("%q", repo .. "/shared/installer/input.lua") .. ")\n")
    while true do
      run({"rm", "-f", "--", work .. "/answer"})
      -- The interactive child claims the terminal. Bash restores our foreground
      -- process group when it exits, so the next Oslo UI prompt can read input.
      local prompt = oslo.run{"bash", "-c", "set -m; \"$@\"", "installer-input",
        "env", "XDG_CONFIG_HOME=" .. work .. "/config", "XDG_DATA_HOME=" .. work .. "/data",
        "OSLO_PROFILE=installer-input", "OSLO_DEFAULT_MODE=sh", "RPS1=", "RPROMPT=",
        "INSTALL_INPUT_SUGGESTION=" .. suggestion, "INSTALL_INPUT_RESULT=" .. work .. "/answer",
        assert(oslo.env.get("OSLO_BIN"), "Launch this through install.sh"), "--noprofile", "-i"}
      if not prompt.ok then die("Cancelled; no disks were changed") end
      local answer = oslo.fs.read(work .. "/answer")
      if not answer then die("Cancelled; no disks were changed") end
      local url = answer:match("^%s*(.-)%s*$")
      if not url:match("^https://[%w.-]+[:%d]*/[^%s]+$") or url:find("[@?#\\]") or url:find("%c") then
        print("Enter an HTTPS Git URL without credentials, query parameters or fragments.")
      else
        print("Checking dotfiles repository...")
        local ok, tree = pcall(function()
          local expression = "let source = builtins.fetchTree { type = \"git\"; url = " .. quoted(url)
            .. "; shallow = true; }; in { path = source.outPath; rev = source.rev; narHash = source.narHash; }"
          return oslo.json.decode(nix("eval", "--refresh", "--impure", "--json", "--expr", expression))
        end)
        if not ok then
          print("Cannot fetch that Git repository: " .. tostring(tree))
        elseif not oslo.run{"test", "-f", tree.path .. "/nix/home.nix"}.ok
          or not oslo.run{"test", "-d", tree.path .. "/.config"}.ok then
          print("The repository must contain nix/home.nix and a .config directory.")
        else
          write(repo .. "/dotfiles.nix", "{\n  url = " .. quoted(url) .. ";\n  rev = " .. quoted(tree.rev)
            .. ";\n  narHash = " .. quoted(tree.narHash) .. ";\n}\n")
          run({"rm", "-rf", "--", work})
          print("Dotfiles repository: " .. url)
          return
        end
      end
      suggestion = url
    end
  end
  if update then
    if not oslo.fs.exists("/etc/nixos/flake.nix") or not oslo.fs.exists("/etc/nixos/user.nix") then
      die("No installed configuration found in /etc/nixos. Choose Install from the live system.")
    end
    for _, name in ipairs({"user.nix", "dotfiles.nix", "machine.nix", "hardware.nix", "disko.nix"}) do copy_if_present(name) end
    if oslo.fs.exists(repo .. "/machine.nix") then
      local machine = oslo.json.decode(nix("eval", "--json", "--file", repo .. "/machine.nix"))
      role, device = machine.profile, machine.device
      if type(device) ~= "string" or not device:match("^[a-z0-9][a-z0-9_-]*$") then die("Invalid saved device name") end
      if not oslo.fs.exists(repo .. "/devices/" .. device .. "/device.json") then
        run({"cp", "-a", "--", "/etc/nixos/devices/" .. device, repo .. "/devices/" .. device})
      end
      info = oslo.json.decode(assert(oslo.fs.read(repo .. "/devices/" .. device .. "/device.json")))
    elseif oslo.run{"sh", "-c", "test -r /proc/device-tree/compatible && tr '\\0' '\\n' < /proc/device-tree/compatible | grep -Fxq fairphone,fp6"}.ok then
      -- Import the account from the initial standalone FP6 installation.
      role, device = "phone", "fp6"
      local username = nix("eval", "--raw", "--file", "/etc/nixos/user.nix", "--apply",
        "module: module.bresilla.phone.user.name or module.bresilla.user.name")
      write(repo .. "/user.nix", "{ bresilla.user.name = " .. quoted(username) .. "; }\n")
      write(repo .. "/machine.nix", '{ profile = "phone"; device = "fp6"; }\n')
      info = oslo.json.decode(assert(oslo.fs.read(repo .. "/devices/fp6/device.json")))
    else
      role = arg[2] or choose("Installed profile", roles)
      -- Preserve older installations' root-level Disko/hardware files.
      if not oslo.fs.exists(repo .. "/disko.nix") and not oslo.fs.exists(repo .. "/hardware.nix") then
        die("This installation needs a device selection or its existing hardware/disko.nix.")
      end
      if role == "laptop" and oslo.run{"cmp", "-s", "/etc/nixos/disko.nix", repo .. "/devices/t480/disko.nix"}.ok then
        device = "t480"
        info = oslo.json.decode(assert(oslo.fs.read(repo .. "/devices/t480/device.json")))
        write(repo .. "/machine.nix", '{ profile = "laptop"; device = "t480"; }\n')
      end
    end
    if not valid_role(role) then die("Unknown profile") end
    select_dotfiles()
    refresh_inputs()
    local config = "path:" .. repo .. "#nixosConfigurations." .. role .. ".config"
    local platform = nix("eval", "--raw", config .. ".nixpkgs.hostPlatform.system")
    local expected = ({x86_64 = "x86_64-linux", aarch64 = "aarch64-linux"})[run({"uname", "-m"}, true)]
    if platform ~= expected then die("Selected device architecture does not match this machine") end
    local prepare = nix("build", "--no-link", "--print-out-paths", config .. ".system.build.prepareDotfiles")
    local boot
    if info and info.install == "fp6" then
      boot = nix("build", "--no-link", "--print-out-paths", config .. ".system.build.fp6BootImage")
      root({"bash", repo .. "/devices/fp6/update-boot.sh", "--check", boot})
    end
    root({prepare})
    root({"nixos-rebuild", "switch", "--flake", "path:" .. repo .. "#" .. role,
      "--option", "accept-flake-config", "true"})
    if boot then root({"bash", repo .. "/devices/fp6/update-boot.sh", boot}) end
    root({"cp", "-a", "--no-preserve=ownership", repo .. "/.", "/etc/nixos/"})
    print("Updated #" .. role .. ". Configuration: /etc/nixos.")
    return
  end

  if oslo.run{"sh", "-c", "test -r /proc/device-tree/compatible && tr '\\0' '\\n' < /proc/device-tree/compatible | grep -Fxq fairphone,fp6"}.ok then
    die("Use Update on the installed FP6. First installation uses the image/Fastboot steps in devices/fp6/README.md.")
  end
  if oslo.run{"mountpoint", "-q", "/mnt"}.ok then die("Unmount /mnt before starting a new installation") end
  local catalog, choices = {}, {}
  for path in run({"find", repo .. "/devices", "-mindepth", "2", "-maxdepth", "2", "-name", "device.json", "-type", "f"}, true):gmatch("[^\n]+") do
    local name = path:match("/devices/([^/]+)/device.json$")
    local data = oslo.json.decode(assert(oslo.fs.read(path)))
    if name and name:match("^[a-z0-9][a-z0-9_-]*$") then
      local label = name .. " (" .. data.profile .. ")"
      catalog[label] = {name = name, data = data}
      table.insert(choices, label)
    end
  end
  table.sort(choices)
  table.insert(choices, "New device")
  local selected = arg[3] and "New device" or choose("Device", choices)
  local layout
  if selected ~= "New device" then
    device, info = catalog[selected].name, catalog[selected].data
    role = info.profile
    if arg[2] and arg[2] ~= role then die("That saved device uses #" .. role) end
    if info.install == "fp6" then
      print("The FP6 uses Android boot images and its existing bootloader, not the live-USB Disko path.")
      run({"cat", repo .. "/devices/fp6/README.md"})
      print("On an already installed FP6, run this installer there and choose Update this machine.")
      return
    end
    if info.install ~= "disko" then die("Unsupported installation method") end
    layout = repo .. "/devices/" .. device .. "/disko.nix"
  else
    role = arg[2] or choose("Profile", roles)
    if not valid_role(role) then die("Choose laptop, server, phone or iot") end
    device = input("Device name", nil, function(value)
      return value:match("^[a-z0-9][a-z0-9_-]*$") and not oslo.fs.exists(repo .. "/devices/" .. value),
        "Choose a new name using lowercase letters, digits, hyphens and underscores"
    end)
    local directory = repo .. "/devices/" .. device
    run({"mkdir", "-p", directory})
    local hardware_options = {"Use an existing hardware.nix"}
    if oslo.fs.exists("/sys/firmware/efi") then table.insert(hardware_options, "Detect this UEFI machine") end
    local generated = choose("Hardware configuration", hardware_options) == "Detect this UEFI machine"
    if generated then
      write(directory .. "/hardware.nix", root({"nixos-generate-config", "--show-hardware-config", "--no-filesystems"}, true))
    else
      print("Select a self-contained hardware module defining this device's kernel and bootloader.")
      local file = ui.file{start = oslo.sys.pwd()}
      if not file then die("Cancelled") end
      run({"cp", "--", file, directory .. "/hardware.nix"})
    end
    layout = arg[3]
    if not layout then
      if choose("Disko layout", {"Use an existing Disko file", "Create a Disko file"}) == "Create a Disko file" then
        layout = directory .. "/disko.nix"
        run({"bash", repo .. "/discio.sh", layout})
      else
        layout = ui.file{start = oslo.sys.pwd()}
        if not layout then die("Cancelled") end
      end
    end
    if not oslo.run{"test", "-f", layout}.ok then die("Disko file not found") end
    if layout ~= directory .. "/disko.nix" then run({"cp", "--", layout, directory .. "/disko.nix"}) end
    layout = directory .. "/disko.nix"
    local platform = ({x86_64 = "x86_64-linux", aarch64 = "aarch64-linux"})[run({"uname", "-m"}, true)]
    if not platform then die("Unsupported CPU architecture") end
    info = {name = device, profile = role, system = platform, install = "disko", boot = generated and "uefi" or "custom"}
    write(directory .. "/device.json", oslo.json.encode(info) .. "\n")
    write(directory .. "/default.nix", '{ imports = [ ./hardware.nix ./disko.nix'
      .. (generated and ' ../lib/uefi.nix' or '') .. ' ]; }\n')
  end
  if info.boot == "uefi" and not oslo.fs.exists("/sys/firmware/efi") then die("Boot the live environment in UEFI mode for this device") end
  local platform = ({x86_64 = "x86_64-linux", aarch64 = "aarch64-linux"})[run({"uname", "-m"}, true)]
  if info.system ~= platform then die("Install from a live environment matching the saved device's architecture") end
  for _, tool in ipairs({"nixos-install", "nixos-enter", "lsblk", "mountpoint"}) do
    if not oslo.run{"sh", "-c", 'command -v "$1"', "installer", tool}.ok then die(tool .. " is required in the live environment") end
  end
  write(repo .. "/machine.nix", "{ profile = " .. quoted(role) .. "; device = " .. quoted(device) .. "; }\n")
  local username = input("Username", nil, function(value)
    return #value <= 32 and value:match("^[a-z_][a-z0-9_-]*$") and value ~= "root", "Choose a valid non-root username"
  end)
  write(repo .. "/user.nix", "{ bresilla.user.name = " .. quoted(username) .. "; }\n")
  select_dotfiles()
  refresh_inputs()
  local flake = "path:" .. repo .. "#nixosConfigurations." .. role .. ".config"
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
  local prepare = nix("build", "--no-link", "--print-out-paths", flake .. ".system.build.prepareDotfiles")
  local swaps = nix("eval", "--raw", flake .. ".swapDevices", "--apply",
    'swaps: builtins.concatStringsSep "\n" (map (swap: swap.device) swaps)')
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
  -- Disko formats swap without enabling it in the live ISO. Use the selected
  -- layout's block devices while building; boot-only encrypted swap is skipped.
  local active_swaps = {}
  for device in run({"swapon", "--show=NAME", "--noheadings", "--raw"}, true):gmatch("[^\n]+") do
    active_swaps[run({"readlink", "-f", "--", device}, true)] = true
  end
  for device in swaps:gmatch("[^\n]+") do
    if oslo.run{"test", "-b", device}.ok then
      local path = run({"readlink", "-f", "--", device}, true)
      if not active_swaps[path] then
        print("Activating installation swap: " .. device)
        root({"swapon", "--", device})
        active_swaps[path] = true
      end
    end
  end
  root({"mkdir", "-p", "/mnt/etc/nixos"})
  root({"cp", "-a", "--no-preserve=ownership", repo .. "/.", "/mnt/etc/nixos/"})
  root({"nixos-install", "--root", "/mnt", "--flake", "path:/mnt/etc/nixos#" .. role,
    "--option", "accept-flake-config", "true",
    "--option", "extra-substituters", "https://termworks.cachix.org",
    "--option", "extra-trusted-public-keys", "termworks.cachix.org-1:Ty7sSVALfD5ajbcWBIdaNHcaEx3fEmVrOo+rSzy0mvE="})
  root({prepare, "/mnt"})
  print("Set the password for " .. username .. ":")
  root({"nixos-enter", "--root", "/mnt", "--", "passwd", username})
  print("Installed #" .. role .. ". Configuration: /etc/nixos. Reboot when ready.")
end
local ok, message = pcall(main)
if not ok then
  io.stderr:write("error: " .. tostring(message) .. "\n")
  os.exit(1)
end
