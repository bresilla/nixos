{ lib, ... }:

{
  # Everything a laptop has; it stays plugged in, boots headless and serves its desktop over RDP.
  imports = [ ../laptop ];

  bresilla.features.system.laptopPower.enable = false;
  bresilla.features.system.tlp.enable = false;

  bresilla.programs.isaacsim.enable = lib.mkDefault true;

  # Boots to a console; the desktop runs only as the remote session, started over SSH
  # with `sudo hypr-remote start`.
  services.greetd.enable = lib.mkForce false;
  systemd.defaultUnit = "multi-user.target";
  # Morf still gives the greeter a home; without greetd it needs to be a system user.
  users.users.greeter = {
    isSystemUser = true;
    group = "greeter";
  };
  users.groups.greeter = { };
  bresilla.system.remote.rdp = {
    enable = lib.mkDefault true;
    autoStart = lib.mkDefault false;
  };
}
