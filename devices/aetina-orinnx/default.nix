{ config, lib, pkgs, jetpack-nixos, ... }:
let
  aetina = ./board/r36;
in
{
  imports = [ jetpack-nixos.nixosModules.default ./disko.nix ];
  networking.hostName = "orin";

  # JetPack 6 (L4T R36), the step from Aetina's R35 firmware towards 7 by capsule updates:
  # its OTG port never reached a host, so it cannot be flashed over USB.
  hardware.nvidia-jetpack = {
    enable = true;
    som = "orin-nx";
    carrierBoard = "devkit";
    majorVersion = "6";
    # Only a step towards 7; CUDA comes back there.
    configureCuda = false;
    # NVIDIA's devkit boot config does not boot the AIB-MN02 (capsule status 2). From Aetina's
    # R36.4.3 patch for it: its pins and GPIOs, no carrier EEPROM read (the board has none),
    # and its lane split, which gives the Intel Ethernet its PCIe link.
    flashScriptOverrides.postPatch = ''
      cp ${aetina}/tegra234-mb1-bct-gpio-p3767-dp-a03.dtsi bootloader/
      cp ${aetina}/tegra234-mb1-bct-pinmux-p3767-dp-a03.dtsi bootloader/generic/BCT/
      cp ${aetina}/tegra234-mb2-bct-misc-p3767-0000.dts bootloader/generic/BCT/
      substituteInPlace p3767.conf.common --replace-fail gbe-uphy-config-8 gbe-uphy-config-9
    '';
  };

  # Aetina's device tree for the Orin NX 8 GB on this carrier: its second Ethernet port and
  # PCIe/USB wiring. The firmware hands it to the kernel, so it goes in both.
  hardware.deviceTree.dtbSource = lib.mkForce (pkgs.runCommand "devicetree-aib-mn02"
    { passthru.src = config.boot.kernelPackages.devicetree.src; } ''
      cp -r ${config.boot.kernelPackages.devicetree}/. $out
      chmod -R u+w $out
      found=$(find $out -name 'tegra234-p3768-0000+p3767-0001-nv.dtb')
      [ -n "$found" ] || { echo "devkit p3767-0001 dtb not found" >&2; exit 1; }
      for f in $found; do cp ${aetina}/tegra234-p3768-0000+p3767-0001-nv.dtb "$f"; done
    '');

  # NVIDIA's kernel has device-mapper but not these targets; LVM loads dm-snapshot at boot.
  boot.kernelPatches = [
    {
      name = "lvm-targets";
      patch = null;
      structuredExtraConfig = with lib.kernel; {
        DM_SNAPSHOT = module;
        DM_THIN_PROVISIONING = module;
        DM_MIRROR = module;
      };
    }
    {
      # The NixOS firewall's rules (ct state, rate limits, reverse-path filter) and iwd's
      # kernel crypto: NVIDIA's config leaves these out.
      name = "firewall-and-iwd";
      patch = null;
      structuredExtraConfig = with lib.kernel; {
        NFT_CT = module;
        NFT_LIMIT = module;
        NFT_FIB_IPV4 = module;
        NFT_FIB_IPV6 = module;
        NFT_FIB_INET = module;
        CRYPTO_USER_API_HASH = module;
        CRYPTO_USER_API_AEAD = module;
      };
    }
  ];

  # JetPack is NVIDIA's: L4T firmware, the CUDA libraries and their tools are all unfree.
  nixpkgs.config.allowUnfree = true;

  # The Jetson UEFI firmware on the module's QSPI starts systemd-boot from the NVMe.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
