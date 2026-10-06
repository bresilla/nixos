-- Oslo provides the widgets; the layout module validates and renders the plan.
local ui = oslo.ui
local model = dofile(arg[1] .. '/discio-layout.lua')
local function die(message) error(message, 0) end
local function choose(header, items, multi)
  local result = ui.choose{header = header, items = items, multi = multi or false}
  if result == nil then die('Cancelled; no disks were changed') end
  return result
end
local function input(prompt, default, validate, optional)
  while true do
    local answer = ui.input{prompt = prompt .. ': ', default = default, required = not optional}
    if answer == nil then die('Cancelled; no disks were changed') end
    local ok, message = validate(answer)
    if ok then return answer end
    print(message or 'Invalid value')
    default = answer
  end
end
local function size(prompt, default, absolute)
  return input(prompt, default, function(value)
    local ok, parsed = pcall(model.size, value, 1024^2)
    return ok and (not absolute or (not value:find('%%') and parsed >= 64)),
      absolute and 'Use an absolute size of at least 64M' or (ok and 'Invalid size' or parsed)
  end)
end
local function title(text)
  print(ui.style{text = text, border = 'rounded', fg = 'cyan', border_fg = 'cyan', padding_x = 2})
end
local function command(argv)
  argv.capture = true
  local result = oslo.run(argv)
  if not result.ok then die('Disk inspection failed: ' .. (result.err or tostring(result.status))) end
  return result.out
end
local function mounted(disk)
  for _, path in ipairs(disk.mountpoints or {}) do
    if type(path) == 'string' and path ~= '' then return true end
  end
  for _, child in ipairs(disk.children or {}) do if mounted(child) then return true end end
  return false
end
local function inspect(remote)
  local text
  if remote then
    -- The remote command is fixed. The host is an argv entry, never interpolated into a shell command.
    if not remote:match('^[a-zA-Z0-9_][a-zA-Z0-9_.@-]*$') then die('Use a host or user@host (SSH aliases are supported)') end
    text = command({'ssh', '--', remote, 'lsblk --json --bytes --paths --output NAME,TYPE,SIZE,MODEL,MOUNTPOINTS'})
  else
    text = command({'lsblk', '--json', '--bytes', '--paths', '--output', 'NAME,TYPE,SIZE,MODEL,MOUNTPOINTS'})
  end
  local data, message = oslo.json.decode(text)
  if not data or type(data.blockdevices) ~= 'table' then die(message or 'Invalid lsblk output') end
  local disks = {}
  for _, disk in ipairs(data.blockdevices) do
    if disk.type == 'disk' and tonumber(disk.size) and tonumber(disk.size) > 0 then
      disk.busy = mounted(disk)
      table.insert(disks, disk)
    end
  end
  if #disks == 0 then die('No disks were found') end
  return disks
end
local function pick(header, records, label, multi)
  local items, lookup = {}, {}
  for _, record in ipairs(records) do
    local text = label(record)
    table.insert(items, text); lookup[text] = record
  end
  local selected = choose(header, items, multi)
  if not multi then return lookup[selected] end
  local result = {}
  for _, text in ipairs(selected) do table.insert(result, lookup[text]) end
  return result
end
local function target_options(layout)
  local choices, seen = {}, {}
  for index, disk in ipairs(layout.disks) do
    local target = layout.storage == 'lvm' and disk.pool or 'disk' .. index
    if not seen[target] then table.insert(choices, target); seen[target] = true end
  end
  return choices
end
local function edit_volume(layout, volume)
  volume.name = input('Volume name', volume.name, model.name)
  if volume.mount ~= '/' then
    local choices = {volume.fs or (volume.mount == 'swap' and 'swap' or 'btrfs')}
    for _, fs in ipairs({'btrfs', 'ext4', 'swap'}) do if fs ~= choices[1] then table.insert(choices, fs) end end
    volume.fs = choose('Filesystem for ' .. volume.name, choices)
    if volume.fs ~= 'swap' then volume.mount = input('Mountpoint', model.mount(volume.mount) and volume.mount or '/data', model.mount) end
  else
    volume.fs = choose('Root filesystem', volume.fs == 'ext4' and {'ext4', 'btrfs'} or {'btrfs', 'ext4'})
  end
  local targets = target_options(layout)
  volume.target = #targets == 1 and targets[1] or choose('Disk or volume group for ' .. volume.name, targets)
  volume.size = size('Size of ' .. volume.name .. ' (100% = remaining space)', volume.size or '32G')
  volume.children = {}
  if volume.fs == 'btrfs' then
    local default = volume.mount == '/doc' and 'code,data,self,work' or ''
    local names = input('Btrfs subdirectories (comma separated, empty for none)', volume.subdirectories or default, function(value)
      local ok, message = pcall(model.subvolumes, value)
      return ok, message
    end, true)
    volume.children = model.subvolumes(names)
    volume.subdirectories = names
  end
end
local function edit_disk(layout, disk)
  if layout.storage == 'lvm' then
    disk.pool = input('Volume group for ' .. disk.device, disk.pool, model.name)
    disk.size = size('Physical volume size on ' .. disk.device, disk.size or '100%')
  else
    print(disk.device .. ': partition sizes are set in the volume editor')
  end
end
local palette = {'cyan', 'green', 'magenta', 'yellow', 'blue'}
local function summary(plan)
  title('DISK LAYOUT · review before saving')
  for _, disk in ipairs(plan.disks) do
    print(string.format('%s  %.1f GiB  → %s%s', disk.device, disk.total / 1024, disk.target,
      disk.efi > 0 and ('  · EFI ' .. disk.efi .. ' MiB at /boot') or ''))
  end
  for _, group in ipairs(plan.groups) do
    local blocks = {}
    for index, volume in ipairs(group.volumes) do
      local width = math.max(1, math.floor(40 * (volume.size + volume.overhead) / group.capacity))
      table.insert(blocks, ui.style{text = string.rep('█', width), fg = palette[(index - 1) % #palette + 1]})
    end
    local free = group.capacity - group.used
    if free > 0 then table.insert(blocks, ui.style{text = string.rep('░', math.max(1, math.floor(40 * free / group.capacity))), fg = 'white'}) end
    if #blocks > 0 then print(ui.join{blocks = blocks, vertical = false, align = 'start'}) end
    print(string.format('%s: %.2f GiB used / %.2f GiB available · %.2f GiB free', group.name, group.used / 1024, group.capacity / 1024, free / 1024))
    for index, volume in ipairs(group.volumes) do
      print(ui.style{text = string.format('  %-12s %8.2f GiB  %-5s %s%s', volume.name, volume.size / 1024, volume.fs,
        volume.fs == 'swap' and '[swap]' or volume.mount,
        #volume.children > 0 and ('  + ' .. table.concat(volume.children, ', ')) or ''), fg = palette[(index - 1) % #palette + 1]})
    end
  end
  if plan.encrypted then print('LUKS enabled · EFI stays unencrypted · Disko will ask for encryption passwords during installation') end
end
local function main()
  local remote, output, index = nil, nil, 2
  while index <= #arg do
    if arg[index] == '--remote' then
      index = index + 1; remote = arg[index]
      if not remote or remote == '' then die('--remote needs user@host') end
    elseif arg[index]:sub(1, 1) == '-' or output then die('Usage: discio.sh [--remote user@host] [output.nix]')
    else output = arg[index] end
    index = index + 1
  end
  title('DISCiO · machine-specific Disko designer')
  print('Select → configure → review → save. This tool only reads disk information and writes a Nix file.')
  local available = inspect(remote)
  local eligible = {}
  for _, disk in ipairs(available) do if not disk.busy then table.insert(eligible, disk) end end
  if choose('Disk visibility', {'Unmounted disks (exclude the live USB)', 'All disks (including mounted disks)'}) == 'All disks (including mounted disks)' then eligible = available end
  if #eligible == 0 then die('No unmounted disks; choose all disks to design a layout for a mounted system') end
  local selected = pick('Select disks · Space toggles · Enter continues', eligible, function(disk)
    return string.format('%s · %.1f GiB · %s%s', disk.name, tonumber(disk.size) / 1024^3, disk.model or '', disk.busy and ' [mounted]' or '')
  end, true)
  if #selected == 0 then die('No disks selected') end
  local layout = {disks = {}, volumes = {}}
  for _, disk in ipairs(selected) do table.insert(layout.disks, {device = disk.name, bytes = tonumber(disk.size), size = '100%'}) end
  layout.boot = #selected == 1 and selected[1].name or pick('Disk for the EFI partition', selected, function(d) return d.name end).name
  layout.efi = size('EFI partition size at /boot', '1G', true)
  layout.storage = choose('Storage', {'LVM volumes', 'Plain partitions'}) == 'LVM volumes' and 'lvm' or 'plain'
  layout.encrypted = choose('Encryption', {'Unencrypted', 'LUKS (password asked during installation)'}) ~= 'Unencrypted'
  if layout.storage == 'lvm' then
    local pooled = #selected == 1 or choose('Volume groups', {'One pool across all disks', 'One group per disk'}) == 'One pool across all disks'
    local pool = pooled and input('Volume group name', 'pool', model.name) or nil
    for i, disk in ipairs(layout.disks) do disk.pool = pool or ('pool' .. i); edit_disk(layout, disk) end
  end
  local root = {name = 'root', mount = '/', size = '100%'}
  edit_volume(layout, root); table.insert(layout.volumes, root)
  local extras = choose('Additional volumes · Space toggles · Enter continues', {'None (root volume only)', '/home', '/nix', '/doc', '/pkg', 'swap', 'Custom mount'}, true)
  local defaults = {['/home'] = '10%', ['/nix'] = '35%', ['/doc'] = '25%', ['/pkg'] = '5%', swap = '4G'}
  for _, mount in ipairs(extras) do
    if mount ~= 'None (root volume only)' then
      local volume = {name = mount == 'Custom mount' and 'data' or mount:gsub('^/', ''), mount = mount == 'Custom mount' and '/data' or mount, size = defaults[mount] or '10%'}
      edit_volume(layout, volume); table.insert(layout.volumes, volume)
    end
  end
  while true do
    local ok, plan = pcall(model.plan, layout)
    if ok then summary(plan) else title('Layout needs attention'); print(plan) end
    local action = choose('Review · edits keep your other choices', {'Save Disko file', 'Preview Nix', 'Edit volume', 'Add volume', 'Remove volume', 'Edit disk / volume group', 'Edit EFI size', 'Cancel'})
    if action == 'Cancel' then die('Cancelled; no disks were changed')
    elseif action == 'Save Disko file' or action == 'Preview Nix' then
      if not ok then print('Fix the layout before previewing or saving')
      elseif action == 'Preview Nix' then ui.pager{text = model.render(plan), title = 'disko.nix', wrap = true}
      else
        local path = output or input('Save Disko file as', oslo.sys.pwd() .. '/disko.nix', function(value) return value ~= '' end)
        if oslo.fs.exists(path) and ui.confirm{question = 'Overwrite ' .. path .. '?', default = false} ~= true then
          print(output and 'Existing file kept; confirm overwriting when ready or cancel'
            or 'Existing file kept; choose a different output path or cancel')
        elseif ui.confirm{question = 'Save this layout? No disks will be changed.', default = false} == true then
          local saved, message = oslo.fs.write(path, model.render(plan))
          if not saved then die(message) end
          print('Saved machine-specific Disko layout: ' .. path)
          return
        end
      end
    elseif action == 'Add volume' then
      local volume = {name = 'data', mount = '/data', size = '10%'}
      edit_volume(layout, volume); table.insert(layout.volumes, volume)
    elseif action == 'Edit volume' or action == 'Remove volume' then
      local volume = pick('Choose volume', layout.volumes, function(v) return v.name .. ' · ' .. v.mount .. ' · ' .. v.size .. ' → ' .. v.target end)
      if action == 'Edit volume' then edit_volume(layout, volume)
      elseif volume.mount == '/' and volume.fs ~= 'swap' then print('The root volume is required')
      else for i, v in ipairs(layout.volumes) do if v == volume then table.remove(layout.volumes, i); break end end end
    elseif action == 'Edit disk / volume group' then
      local disk = pick('Choose disk', layout.disks, function(d) return d.device end)
      edit_disk(layout, disk)
    elseif action == 'Edit EFI size' then layout.efi = size('EFI partition size at /boot', layout.efi, true) end
  end
end
local ok, message = pcall(main)
if not ok then io.stderr:write('error: ' .. tostring(message) .. '\n'); os.exit(1) end
