-- Pure layout planning: sizes are resolved before rendering Disko's Nix module.
local M = {}
local MiB = 1024^2
local function fail(message) error(message, 0) end
local function quote(value)
  return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('%${', '\\${') .. '"'
end
M.quote = quote
local units = {K = 1/1024, M = 1, G = 1024, T = 1024^2}
function M.size(value, capacity)
  if value == '100%' then return 'remaining' end
  local percent = value:match('^(%d+%.?%d*)%%$')
  if percent then
    percent = tonumber(percent)
    if percent <= 0 or percent >= 100 then fail('Percentages must be greater than 0 and at most 100') end
    return math.floor(capacity * percent / 100)
  end
  local count, unit = value:upper():match('^(%d+%.?%d*)([KMGT])I?B?$')
  if not count then fail('Use a size such as 512M, 32G, 1.5T, 25%, or 100% for remaining space') end
  return math.floor(tonumber(count) * units[unit])
end
function M.name(value)
  return type(value) == 'string' and #value <= 63 and value:match('^[a-zA-Z][a-zA-Z0-9_-]*$') ~= nil
end
function M.mount(value)
  return type(value) == 'string' and (value == '/' or
    (value:match('^/[a-zA-Z0-9_/-]+$') and not value:find('//', 1, true) and value:sub(-1) ~= '/'))
end
function M.subvolumes(value)
  local result, seen = {}, {}
  for part in (value .. ','):gmatch('(.-),') do
    part = part:match('^%s*(.-)%s*$')
    if part ~= '' then
      if not part:match('^[a-zA-Z0-9_-]+$') or seen[part] then fail('Use unique subdirectory names separated by commas') end
      seen[part] = true
      table.insert(result, part)
    end
  end
  return result
end
function M.plan(layout)
  if layout.storage ~= 'lvm' and layout.storage ~= 'plain' then fail('Unknown storage layout') end
  if #layout.disks == 0 then fail('Choose at least one disk') end
  local disks, containers, order, mounts, names, devices = {}, {}, {}, {}, {}, {}
  local function claim_mount(path)
    if not M.mount(path) or path == '/boot' or mounts[path] then fail('Invalid or repeated mountpoint: ' .. tostring(path)) end
    mounts[path] = true
  end
  local function container(name)
    if not containers[name] then
      containers[name] = {name = name, capacity = 0, used = 0, volumes = {}}
      table.insert(order, containers[name])
    end
    return containers[name]
  end
  local boot
  for index, spec in ipairs(layout.disks) do
    if type(spec.device) ~= 'string' or not spec.device:match('^/dev/[a-zA-Z0-9/_:%.+-]+$') or devices[spec.device] then fail('Invalid or repeated disk device') end
    devices[spec.device] = true
    if layout.storage == 'lvm' and not M.name(spec.pool) then fail('Invalid volume group name') end
    local total = math.floor(tonumber(spec.bytes) / MiB)
    local disk = {key = 'disk' .. index, device = spec.device, total = total, efi = 0, volumes = {}}
    if spec.device == layout.boot then
      if boot then fail('Repeated EFI disk') end
      boot = disk
      disk.efi = M.size(layout.efi, total)
      if disk.efi == 'remaining' or disk.efi < 64 then fail('EFI needs an absolute size of at least 64M') end
    end
    local available = total - disk.efi - 8 -- GPT/alignment margin
    if available < 16 then fail('No usable space on ' .. spec.device) end
    local target = layout.storage == 'lvm' and spec.pool or disk.key
    disk.target = target
    if layout.storage == 'lvm' then
      disk.pv = M.size(spec.size or '100%', available)
      if disk.pv == 'remaining' then disk.pv = available end
      if disk.pv < 16 or disk.pv > available then fail('Physical volume does not fit on ' .. spec.device) end
      disk.capacity = math.floor((disk.pv - (layout.encrypted and 32 or 0) - 4) / 4) * 4
    else
      disk.capacity = available
    end
    if disk.capacity < 16 then fail('No usable space on ' .. spec.device) end
    local group = container(target)
    group.capacity = group.capacity + disk.capacity
    table.insert(disks, disk)
  end
  if not boot then fail('Choose an EFI disk from the selected disks') end
  local root_count = 0
  for _, spec in ipairs(layout.volumes) do
    local group = containers[spec.target]
    if not group then fail('Choose a valid target for ' .. tostring(spec.name)) end
    if not M.name(spec.name) then fail('Invalid volume name') end
    local key = spec.target .. '/' .. spec.name
    if names[key] or (layout.storage == 'plain' and spec.name == 'ESP') then fail('Repeated or reserved volume name: ' .. spec.name) end
    names[key] = true
    if spec.fs ~= 'btrfs' and spec.fs ~= 'ext4' and spec.fs ~= 'swap' then fail('Unknown filesystem') end
    local volume = {name = spec.name, target = spec.target, mount = spec.mount, fs = spec.fs, children = spec.children or {}}
    if spec.fs ~= 'swap' then
      claim_mount(spec.mount)
      if spec.mount == '/' then root_count = root_count + 1 end
      if spec.fs ~= 'btrfs' and #volume.children > 0 then fail('Subvolumes require Btrfs') end
      local child_names = {}
      for _, child in ipairs(volume.children) do
        if type(child) ~= 'string' or not child:match('^[a-zA-Z0-9_-]+$') or child_names[child] then fail('Invalid or repeated Btrfs subvolume') end
        child_names[child] = true
        claim_mount((spec.mount == '/' and '' or spec.mount) .. '/' .. child)
      end
    end
    volume.size = M.size(spec.size, group.capacity)
    local overhead = layout.storage == 'plain' and layout.encrypted and 32 or 0
    volume.overhead = overhead
    if volume.size == 'remaining' then
      if group.remaining then fail('Only one 100% volume is allowed per disk or volume group') end
      group.remaining = volume
      group.used = group.used + overhead
    else
      if layout.storage == 'lvm' then volume.size = math.floor(volume.size / 4) * 4 end
      if volume.size < 16 then fail('Volumes need at least 16M') end
      group.used = group.used + volume.size + overhead
    end
    table.insert(group.volumes, volume)
  end
  if root_count ~= 1 then fail('The layout must mount exactly one root filesystem at /') end
  for _, group in ipairs(order) do
    if group.remaining then
      local size = group.capacity - group.used
      if layout.storage == 'lvm' then size = math.floor(size / 4) * 4 end
      if size < 16 then fail('Volumes exceed capacity in ' .. group.name) end
      group.remaining.size = size
      group.used = group.used + size
    end
    if group.used > group.capacity then fail('Volumes exceed capacity in ' .. group.name) end
  end
  for _, disk in ipairs(disks) do disk.volumes = containers[disk.target].volumes end
  return {disks = disks, groups = order, encrypted = layout.encrypted, storage = layout.storage}
end
local function content(volume)
  if volume.fs == 'swap' then return '{ type = "swap"; }' end
  if volume.fs == 'ext4' then return '{ type = "filesystem"; format = "ext4"; mountpoint = ' .. quote(volume.mount) .. '; }' end
  local lines = {'{ type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = {'}
  local function subvolume(name, path)
    table.insert(lines, quote('/@' .. name) .. ' = { mountpoint = ' .. quote(path) .. '; mountOptions = [ "noatime" "compress=zstd:3" "ssd" ]; };')
  end
  subvolume(volume.name, volume.mount)
  for _, child in ipairs(volume.children) do
    subvolume(volume.name .. '-' .. child, (volume.mount == '/' and '' or volume.mount) .. '/' .. child)
  end
  table.insert(lines, '}; }')
  return table.concat(lines, ' ')
end
local function encrypt(body, name, enabled)
  if not enabled then return body end
  return '{ type = "luks"; name = ' .. quote(name) .. '; askPassword = true; content = ' .. body .. '; }'
end
function M.render(plan)
  local lines = {'# Machine-specific layout generated by discio.sh; review devices before installing.', '{', '  disko.devices = {'}
  local function add(line) table.insert(lines, line) end
  for _, disk in ipairs(plan.disks) do
    add('    disk.' .. quote(disk.key) .. ' = { type = "disk"; device = ' .. quote(disk.device) .. ';')
    add('      content = { type = "gpt"; partitions = {')
    if disk.efi > 0 then
      add('        ESP = { priority = 1; size = ' .. quote(disk.efi .. 'M') .. '; type = "EF00";')
      add('          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; }; };')
    end
    if plan.storage == 'lvm' then
      local body = '{ type = "lvm_pv"; vg = ' .. quote(disk.target) .. '; }'
      add('        pv = { size = ' .. quote(disk.pv .. 'M') .. '; content = ' .. encrypt(body, 'crypt-' .. disk.key, plan.encrypted) .. '; };')
    else
      for index, volume in ipairs(disk.volumes) do
        add('        ' .. quote(volume.name) .. ' = { priority = ' .. (index + 10) .. '; size = ' .. quote((volume.size + volume.overhead) .. 'M') .. ';')
        add('          content = ' .. encrypt(content(volume), 'crypt-' .. disk.key .. '-' .. volume.name, plan.encrypted) .. '; };')
      end
    end
    add('      }; }; };')
  end
  if plan.storage == 'lvm' then
    for _, group in ipairs(plan.groups) do
      add('    lvm_vg.' .. quote(group.name) .. ' = { type = "lvm_vg"; lvs = {')
      for _, volume in ipairs(group.volumes) do
        add('      ' .. quote(volume.name) .. ' = { size = ' .. quote(volume.size .. 'M') .. '; content = ' .. content(volume) .. '; };')
      end
      add('    }; };')
    end
  end
  add('  };\n}\n')
  return table.concat(lines, '\n')
end
return M
