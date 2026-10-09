{ config, lib, ... }:
let
  cfg = config.bresilla.features.system;
  caches = builtins.attrValues (builtins.fromJSON (builtins.readFile ./caches.json));
in
{
  options.bresilla.features.system.virtualisation.enable =
    lib.mkEnableOption "libvirt and QEMU virtualisation";

  config = lib.mkMerge [
    {
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      nix.settings.auto-optimise-store = true;
      nix.settings.substituters = [ "https://cache.nixos.org" ] ++ map (cache: cache.url) caches;
      nix.settings.trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ] ++ map (cache: cache.key) caches;

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

      security.protectKernelImage = lib.mkDefault true;
      security.sudo.wheelNeedsPassword = lib.mkDefault true;
      services.dbus.implementation = "broker";
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

      system.stateVersion = "26.05";
    }

    (lib.mkIf cfg.virtualisation.enable {
      virtualisation.libvirtd.enable = true;
      programs.virt-manager.enable = true;
    })
  ];
}
