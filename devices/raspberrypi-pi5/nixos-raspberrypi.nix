# Raspberry Pi kernel, firmware and boot setup for this board only; its own nixpkgs
# keeps its cache hits. Fetched by commit, so only rasp ever downloads it.
builtins.getFlake "git+https://github.com/nvmd/nixos-raspberrypi?rev=1206539a806c46f3361c8d66690fff3fc9ef870a&shallow=1"
