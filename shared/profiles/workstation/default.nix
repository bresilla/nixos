{ lib, ... }:

{
  # Everything a laptop has; it stays plugged in and serves its desktop over RDP.
  imports = [ ../laptop ];

  bresilla.features.system.laptopPower.enable = false;
  bresilla.features.system.tlp.enable = false;

  bresilla.system.remote.rdp = {
    enable = lib.mkDefault true;
    autoStart = lib.mkDefault true;
  };
}
