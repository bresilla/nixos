{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (if builtins.pathExists ./disko.nix then ./disko.nix else
      throw "Create a machine-specific disko.nix in this checkout, or supply one to install.sh.")
    ./modules/common.nix
    ./modules/accounts.nix
    ./modules/features.nix
    ./modules/programms/termworks.nix
    ./modules/programms/paneworks.nix
    ./modules/programms/essential.nix
    ./modules/programms/system.nix
    ./modules/programms/desktop.nix
    ./modules/programms/bin.nix
    ./modules/programms/flatpak.nix
    ./modules/programms/appimage.nix
    ./modules/services/resolver.nix
    ./modules/services/netbird.nix
    ./modules/services/tailscale.nix
    ./modules/services/vpn-clients.nix
    ./modules/services/wireguard.nix
    ./modules/services/socketcan.nix
  ] ++ (if builtins.pathExists ./user.nix then [ ./user.nix ] else [ ]);

  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod"
  ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
