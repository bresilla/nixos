{ config, lib, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;
  nix.settings.substituters = [
    "https://cache.nixos.org"
    "https://termworks.cachix.org"
    "https://paneworks.cachix.org"
  ];
  nix.settings.trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "termworks.cachix.org-1:Ty7sSVALfD5ajbcWBIdaNHcaEx3fEmVrOo+rSzy0mvE="
    "paneworks.cachix.org-1:5XAOHaQHgDEM4dL1Cpu56zcKZxUWYP7zmv8GD3Siy0Q="
  ];
  nix.settings.trusted-users = [
    config.bresilla.user.name
  ];

  environment.etc."gitconfig".text = ''
    [safe]
      directory = /etc/nixos
  '';

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  time.timeZone = "Europe/Amsterdam";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";
  services.xserver.xkb = {
    layout = "us";
    variant = "euro";
  };

  boot.loader.systemd-boot.configurationLimit = 5;
  boot.kernelParams = [ "panic=10" ];
  boot.tmp.cleanOnBoot = true;
  hardware.enableRedistributableFirmware = true;
  boot.kernel.sysctl = {
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.unprivileged_bpf_disabled" = 1;
    "kernel.sysrq" = 0;
  };

  bresilla.features.network.networkmanager.enable = lib.mkDefault true;
  bresilla.features.system.firmware.enable = lib.mkDefault true;

  networking.firewall.enable = true;
  networking.nftables.enable = true;
  networking.enableIPv6 = true;

  security.apparmor.enable = lib.mkDefault true;
  security.protectKernelImage = lib.mkDefault true;
  security.sudo.wheelNeedsPassword = lib.mkDefault true;
  services.dbus.implementation = "broker";
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "no";
  };
  services.journald.extraConfig = ''
    Storage=persistent
    MaxRetentionSec=15day
  '';
  services.fstrim.enable = true;
  services.timesyncd.enable = true;
  systemd.oomd.enable = true;
  systemd.tmpfiles.rules = [
    "q /var/tmp 1777 root root 7d"
  ];
  services.btrfs.autoScrub = {
    enable = builtins.any (fs: fs.fsType == "btrfs") (builtins.attrValues config.fileSystems);
    interval = "monthly";
  };
  services.smartd.enable = lib.mkDefault true;
  services.rpcbind.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    nssmdns6 = true;
  };

  system.stateVersion = "26.05";
}
