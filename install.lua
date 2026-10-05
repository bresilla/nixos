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
  local update = false
  if oslo.fs.exists("/etc/nixos/disko.nix") and oslo.fs.exists("/etc/nixos/user.nix") then
    update = choose("Action", {"Update this machine", "Fresh installation"}) == "Update this machine"
  end
  if not update and oslo.run{"mountpoint", "-q", "/mnt"}.ok then die("Unmount /mnt before starting a new installation") end
  local role = arg[2] or choose("Configuration", {"laptop", "server"})
  if role ~= "laptop" and role ~= "server" then die("Configuration must be laptop or server") end
  local function nix(command, ...)
    local argv = {"nix", "--extra-experimental-features", "nix-command flakes", "--accept-flake-config", command}
    for _, value in ipairs({...}) do table.insert(argv, value) end
    return run(argv, true)
  end
  local function refresh_inputs()
    print("Refreshing all flake inputs to their latest upstream revisions...")
    run({"nix", "--extra-experimental-features", "nix-command flakes", "--accept-flake-config",
      "flake", "update", "--refresh", "--flake", "path:" .. repo})
  end
  local function select_dotfiles()
    local suggestion = "https://github.com/bresilla/dot.git"
    if update and oslo.fs.exists("/etc/nixos/dotfiles.nix") then
      suggestion = nix("eval", "--raw", "--file", "/etc/nixos/dotfiles.nix", "--apply", "settings: settings.url")
    end
    print("Dotfiles must be a public HTTPS Git repository with nix/home.nix and a .config directory.")
    print("The Home Manager module must evaluate for the selected user and link to their ~/.dot checkout.")
    local work = repo .. "/.dotfiles-input"
    run({"mkdir", "-p", work .. "/config/oslo"})
    write(work .. "/config/oslo/init.lua", "dofile(" .. string.format("%q", repo .. "/input.lua") .. ")\n")
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
    run({"cp", "--", "/etc/nixos/disko.nix", repo .. "/disko.nix"})
    run({"cp", "--", "/etc/nixos/user.nix", repo .. "/user.nix"})
    select_dotfiles()
    refresh_inputs()
    local as_root = run({"id", "-u"}, true) ~= "0"
    local function root_update(argv)
      if as_root then table.insert(argv, 1, "sudo") end
      run(argv)
    end
    print("Updating #" .. role .. " using this machine's Disko file and user configuration...")
    local prepare = nix("build", "--no-link", "--print-out-paths",
      "path:" .. repo .. "#nixosConfigurations." .. role .. ".config.system.build.prepareDotfiles")
    root_update({prepare})
    root_update({"nixos-rebuild", "switch", "--flake", "path:" .. repo .. "#" .. role,
      "--option", "accept-flake-config", "true"})
    root_update({"cp", "-a", "--no-preserve=ownership", repo .. "/.", "/etc/nixos/"})
    print("Updated #" .. role .. ". Configuration: /etc/nixos.")
    return
  end
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
  select_dotfiles()
  refresh_inputs()
  local as_root = run({"id", "-u"}, true) ~= "0"
  if as_root then run({"sudo", "-v"}) end
  local function root(argv)
    if as_root then table.insert(argv, 1, "sudo") end
    return run(argv)
  end
  if layout ~= repo .. "/disko.nix" then run({"cp", "--", layout, repo .. "/disko.nix"}) end
  write(repo .. "/user.nix", "{ bresilla.user.name = " .. quoted(username) .. "; }\n")
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
