-- Run with: oslo --norc tests/installer.lua /path/to/repository
-- All installer commands and writes are intercepted; no disks are touched.
local root = assert(arg[1], 'repository path required')
local real = oslo
local source = assert(real.fs.read(root .. '/shared/installer/install.lua'))
local function check(label, spec)
  local files, calls, messages = {}, {}, {}
  local hardware = {kernel='/mock/kernel',modules='/mock/modules',firmware='/mock/firmware',version='7.2.0',modDirVersion='7.2.0',configText='CONFIG_MODULES=y'}
  hardware.extraModules = {'/mock/touchscreen-module'}
  local has_dotfiles = spec.update and not spec.missingDotfiles
  if spec.update then
    files['/etc/nixos/flake.nix'] = '{}'
    files['/etc/nixos/user.nix'] = '{ bresilla.user.name = "tester"; }'
    if not spec.migrate then files['/etc/nixos/machine.nix'] = '{}' end
    if spec.migrate == 't480' then files['/etc/nixos/disko.nix'] = '{}' end
    if has_dotfiles then files['/etc/nixos/dotfiles.nix'] = '{ url = "https://example.org/saved-dot.git"; }' end
    if spec.savedHardware then files['/etc/nixos/boot-hardware.json'] = real.json.encode(hardware) end
  end
  local function exists(path)
    if path == '/sys/firmware/efi' then return not spec.arm end
    if path:sub(1, 11) == '/etc/nixos/' then return files[path] ~= nil end
    return files[path] ~= nil or real.fs.exists(path)
  end
  local function read(path) return files[path] or real.fs.read(path) end
  local fake = {
    fs = { exists = exists, read = read, write = function(path, text) files[path] = text; return true end },
    json = real.json, env = {get = function(name) if name == 'OSLO_BIN' then return '/mock/oslo' end end},
    sys = {pwd = function() return '/work' end},
    ui = {
      choose = function(opts)
        assert(not spec.update, 'normal Update must not ask setup questions: '..opts.header)
        local answers = {
          Action = spec.update and 'Update this machine' or 'Install',
          Device = spec.device or 't480 (laptop)',
          Profile = 'laptop',
          ['Installed profile'] = 'laptop',
          ['Hardware configuration'] = 'Detect this UEFI machine',
          ['Disko layout'] = 'Use an existing Disko file',
        }
        return assert(answers[opts.header], 'unexpected menu: '..opts.header)
      end,
      input = function(opts)
        if opts.prompt:find('Device name', 1, true) then return 'test-device' end
        if opts.prompt:find('Username', 1, true) then return 'tester' end
        if opts.prompt:find('Type ', 1, true) then return spec.confirm and '/dev/test-disk' or 'cancel' end
        error('unexpected input: '..opts.prompt)
      end,
      file = function() return '/work/layout.nix' end,
    },
  }
  fake.run = function(argv)
    local a = {}; for _, v in ipairs(argv) do a[#a+1] = v end
    calls[#calls+1] = a
    if a[1] == 'sudo' then table.remove(a, 1) end
    local command, joined = a[1], table.concat(a, ' ')
    local out, ok = '', true
    if command == 'id' then out = '1000'
    elseif command == 'uname' then out = a[2] == '-r' and '7.2.0' or (spec.arm and 'aarch64' or 'x86_64')
    elseif command == 'gzip' then out = 'CONFIG_MODULES=y'
    elseif command == 'mountpoint' then ok = false
    elseif command == 'find' then out = root..'/devices/t480/device.json\n'..root..'/devices/fp6/device.json'
    elseif command == 'cp' then
      local from, to = a[#a-1], a[#a]
      files[to] = files[from] or '{}'
    elseif command == 'nixos-generate-config' then out = '{ boot.initrd.availableKernelModules = [ "nvme" ]; }'
    elseif command == 'bash' and joined:find('installer-input', 1, true) then
      assert(not has_dotfiles, 'Update must not prompt for existing dotfiles')
      for _, value in ipairs(a) do
        local result = value:match('^INSTALL_INPUT_RESULT=(.*)$')
        if result then files[result] = 'https://example.org/dot.git' end
      end
    elseif command == 'nix' then
      if joined:find(' build ', 1, true) then
        assert(argv.capture_out and not argv.capture, 'build progress must remain visible')
      end
      if joined:find('builtins.fetchTree', 1, true) then
        if has_dotfiles then assert(joined:find('https://example.org/saved-dot.git', 1, true), 'saved dotfiles URL was replaced') end
        ok = not spec.dotfilesFail
        out = real.json.encode{path='/mock/dot',rev='abc',narHash='sha256-test'}
      elseif joined:find('config = builtins.removeAttrs', 1, true) then out = real.json.encode(hardware)
      elseif joined:find('/dotfiles.nix', 1, true) then out = 'https://example.org/saved-dot.git'
      elseif joined:find('/etc/nixos/user.nix', 1, true) then out = 'tester'
      elseif joined:find('machine.nix', 1, true) then out = real.json.encode{profile=spec.arm and 'phone' or 'laptop',device=spec.arm and 'fp6' or 't480'}
      elseif joined:find('hostPlatform.system', 1, true) then out = spec.arm and 'aarch64-linux' or 'x86_64-linux'
      elseif joined:find('disko.devices.disk', 1, true) then out = '/dev/test-disk'
      elseif joined:find('prepareDotfiles', 1, true) then out = '/mock/prepare'
      elseif joined:find('diskoScript', 1, true) then out = '/mock/erase'
      elseif joined:find('fp6BootImage', 1, true) then out = '/mock/boot.img'
      elseif joined:find('drvPath', 1, true) then out = '/mock/system.drv'
      end
    elseif command == 'lsblk' then
      if joined:find(' TYPE ', 1, true) then out = 'disk'
      elseif joined:find('MOUNTPOINT', 1, true) then out = spec.mounted and '/' or '' end
    elseif command == 'readlink' then
      out = ({['/run/current-system/kernel']=spec.badKernel and '/mock/wrong/Image' or hardware.kernel..'/Image',
        ['/run/current-system/kernel-modules']=hardware.modules,
        ['/run/current-system/firmware']=hardware.firmware..'/lib/firmware'})[a[#a]] or a[#a]
    elseif command == 'sh' and joined:find('fairphone,fp6', 1, true) then ok = spec.arm == true
    elseif command == 'test' or command == 'mkdir' or command == 'rm' or command == 'cat' or command == 'cmp'
      or command == 'sh' or command == 'swapon' or command == 'nixos-install'
      or command == 'nixos-enter' or command == 'nixos-rebuild' or command == '/mock/prepare'
      or command == '/mock/erase' or command == 'bash' then
      -- Recognized effects remain mocked.
    else error('unexpected command: '..joined) end
    return {ok=ok,status=ok and 0 or 1,out=out,err='mock failure'}
  end
  local env = setmetatable({oslo=fake,arg={[1]=root},
    print=function(...) messages[#messages+1]=table.concat({...}, ' ') end,
    io={stderr={write=function(_, text) messages[#messages+1]=text end}},
    os={exit=function(status) error('installer-exit-'..status, 0) end},
  }, {__index=_G})
  local success, problem = pcall(assert(load(source, '@install.lua', 't', env)))
  assert(success == not spec.fail, label..': '..tostring(problem)..' '..table.concat(messages,'\n'))
  local erase, rebuild, bootcheck, bootwrite = false, nil, nil, nil
  for index, call in ipairs(calls) do
    local text = table.concat(call, ' ')
    if call[1] == '/mock/erase' then erase = true end
    if call[1] == 'nixos-rebuild' then rebuild = index end
    if text:find('update-boot.sh --check', 1, true) then bootcheck = index
    elseif text:find('update-boot.sh', 1, true) then bootwrite = index end
  end
  assert(erase == (spec.confirm == true and not spec.fail and not spec.update), label..': unsafe erasure path')
  if spec.update and not spec.fail then
    assert(rebuild, label..': system update missing')
    if spec.arm then
      assert(bootcheck and bootwrite and bootcheck < rebuild and rebuild < bootwrite, label..': boot update order incorrect')
      local saved = real.json.decode(assert(files[root..'/boot-hardware.json']))
      assert(saved.extraModules[1] == hardware.extraModules[1], label..': touchscreen module was lost')
    else
      assert(not bootcheck and not bootwrite, label..': PC must not write Android boot partitions')
    end
  end
  if spec.migrate and not spec.fail then
    assert(files[root..'/machine.nix']:find(spec.migrate, 1, true), label..': device selection not migrated')
    if spec.arm then
      assert(files[root..'/user.nix'] == '{ bresilla.user.name = "tester"; }\n', label..': account not migrated')
    end
  end
  if spec.device == 'New device' then
    assert(files[root..'/devices/test-device/hardware.nix']:find('nvme', 1, true), 'hardware detection not saved')
    assert(files[root..'/machine.nix']:find('test-device', 1, true), 'device selection not saved')
  end
  print('PASS '..label)
end
check('saved FP6 selects image instructions only', {device='fp6 (phone)'})
check('running FP6 rejects the generic disk installer', {arm=true,fail=true})
check('cancelled disk confirmation never erases', {fail=true})
check('mounted disk is rejected', {mounted=true,confirm=true,fail=true})
check('new device saves detected hardware and Disko', {device='New device',confirm=true})
check('FP6 native update checks and installs its boot image', {update=true,arm=true})
check('standalone FP6 prompts only for missing dotfiles and records existing hardware', {update=true,arm=true,migrate='fp6',missingDotfiles=true})
check('installed T480 layout migrates without formatting', {update=true,migrate='t480'})
check('saved T480 updates without setup prompts', {update=true})
check('saved FP6 reuses existing hardware and dotfiles', {update=true,arm=true,savedHardware=true})
check('saved dotfiles fetch failure does not fall back to setup', {update=true,dotfilesFail=true,fail=true})
check('FP6 refuses a mismatched installed kernel', {update=true,arm=true,savedHardware=true,badKernel=true,fail=true})
