{ config, lib, pkgs, jetpack-nixos, ... }:
let
  # The firmware climbs by capsule: Aetina's R35.4.1 -> 5 (R35.6) -> 6 (R36) -> 7 (R39).
  # R35.4.1 has no partitions for an R36 capsule, so 5 must be installed first.
  jetpack = "7";
  aetina = ./board/r36;
  # Aetina's tree for the Orin NX 8 GB on this carrier: its Intel Ethernet and PCIe/USB wiring.
  dtb =
    if jetpack == "5" then {
      name = "tegra234-p3767-0001-p3768-0000-a0.dtb";
      file = ./board/kernel_tegra234-p3767-0001-p3768-0000-a0.dtb;
      dtbs = "${config.boot.kernelPackages.kernel}/dtbs";
    } else {
      name = "tegra234-p3768-0000+p3767-0001-nv.dtb";
      file = "${aetina}/tegra234-p3768-0000+p3767-0001-nv.dtb";
      dtbs = config.boot.kernelPackages.devicetree;
    };
in
{
  imports = [ jetpack-nixos.nixosModules.default ./disko.nix ];
  networking.hostName = "orin";

  # Its OTG port never reached a host, so the firmware can only change by capsule update.
  hardware.nvidia-jetpack = {
    enable = true;
    som = "orin-nx";
    carrierBoard = "devkit";
    majorVersion = jetpack;
    # CUDA 13 on JetPack 7; the steps before it ran without (JetPack 5's CUDA needs GCC 10).
    configureCuda = jetpack == "7";
    # NVIDIA's devkit boot config does not boot the AIB-MN02 (capsule status 2). From Aetina's
    # R36.4.3 patch for it, identical to NVIDIA's in R35 and R36 apart from these: its pins and
    # GPIOs, no carrier EEPROM read (the board has none), and the lane split the Intel Ethernet
    # needs. R36 renamed the BCT directory from t186ref to generic.
    flashScriptOverrides.postPatch = ''
      bct=bootloader/generic/BCT
      [ -d "$bct" ] || bct=bootloader/t186ref/BCT
      cp ${aetina}/tegra234-mb1-bct-gpio-p3767-dp-a03.dtsi bootloader/
      cp ${aetina}/tegra234-mb1-bct-pinmux-p3767-dp-a03.dtsi "$bct/"
      cp ${aetina}/tegra234-mb2-bct-misc-p3767-0000.dts "$bct/"
      substituteInPlace p3767.conf.common --replace-fail gbe-uphy-config-8 gbe-uphy-config-9
    '';
  };

  # The firmware hands this tree to the kernel, so it goes in both. Aetina has none for R39's
  # 6.8 kernel, so JetPack 7 boots NVIDIA's devkit tree (Realtek port and NVMe wired the same).
  hardware.deviceTree.dtbSource = lib.mkIf (jetpack != "7") (lib.mkForce (pkgs.runCommand "devicetree-aib-mn02"
    { passthru.src = (config.boot.kernelPackages.devicetree or config.boot.kernelPackages.kernel).src; } ''
      cp -r ${dtb.dtbs}/. $out
      chmod -R u+w $out
      found=$(find $out -name '${dtb.name}')
      [ -n "$found" ] || { echo "devkit ${dtb.name} not found" >&2; exit 1; }
      for f in $found; do cp ${dtb.file} "$f"; done
    ''));

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
