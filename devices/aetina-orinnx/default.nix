{ config, lib, pkgs, firmwares, ... }:
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
  imports = [ (import ./jetpack-nixos.nix).nixosModules.default ./disko.nix ];
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
  # 6.8 kernel, so JetPack 7 edits NVIDIA's devkit tree with Aetina's R36 changes instead: its
  # R39 symbols name no USB pad lanes, so an overlay could not reference usb3-2.
  hardware.deviceTree.dtbSource = lib.mkForce (pkgs.runCommand "devicetree-aib-mn02"
    {
      passthru.src = (config.boot.kernelPackages.devicetree or config.boot.kernelPackages.kernel).src;
      nativeBuildInputs = [ pkgs.buildPackages.dtc ];
    } ''
      cp -r ${dtb.dtbs}/. $out
      chmod -R u+w $out
      found=$(find $out -name '${dtb.name}')
      [ -n "$found" ] || { echo "devkit ${dtb.name} not found" >&2; exit 1; }
      for f in $found; do
        ${if jetpack == "7" then ''
          pad=/bus@0/padctl@3520000
          # The third USB 3 port, paired with USB 2 port 1, and its lane on the controller.
          fdtput -t s "$f" $pad/pads/usb3/lanes/usb3-2 status okay
          fdtput -t s "$f" $pad/ports/usb3-2 status okay
          fdtput -t u "$f" $pad/ports/usb3-2 nvidia,usb2-companion 1
          lane=$(fdtget -t u "$f" $pad/pads/usb3/lanes/usb3-2 phandle 2>/dev/null || true)
          if [ -z "$lane" ]; then
            lane=$(( $(dtc -I dtb -O dts "$f" 2>/dev/null | grep -oE 'phandle = <0x[0-9a-f]+>' \
              | grep -oE '0x[0-9a-f]+' | sort -u | xargs printf '%d\n' | sort -n | tail -1) + 1 ))
            fdtput -t u "$f" $pad/pads/usb3/lanes/usb3-2 phandle "$lane"
          fi
          fdtput -t u "$f" /bus@0/usb@3610000 phys $(fdtget -t u "$f" /bus@0/usb@3610000 phys) "$lane"
          fdtput -t s "$f" /bus@0/usb@3610000 phy-names usb2-0 usb2-1 usb2-2 usb3-0 usb3-1 usb3-2
          # UART B is the board's serial port; SPI 3210000's pins are its GPIOs.
          fdtput -t s "$f" /bus@0/serial@3110000 status okay
          fdtput -t s "$f" /aliases serial2 /bus@0/serial@3110000
          fdtput -t s "$f" /bus@0/spi@3210000 status disabled
          # Holds the M.2 B-key slot out of reset (AON GPIO 19).
          hog=/bus@0/gpio@c2f0000/bkey-control-output-high
          fdtput -c "$f" $hog
          fdtput -t u "$f" $hog gpios 19 0
          fdtput -t s "$f" $hog label RST_M2_BKEY
          fdtput "$f" $hog gpio-hog
          fdtput "$f" $hog output-high
        '' else ''
          cp ${dtb.file} "$f"
        ''}
      done
    '');

  # Aetina's fan curve: this fan has no tachometer, so no RPM targets.
  services.nvfancontrol.configFile = lib.mkForce "${aetina}/nvfancontrol.conf";

  # Aetina names the board's internal USB serial converter.
  services.udev.extraRules = ''
    ACTION=="add", ENV{ID_PATH}=="platform-3610000.usb-usb-0:3.4:1.0", ENV{SUBSYSTEM}=="tty", SYMLINK+="usbSerial0"
  '';

  # The devkit tree lists its USB-C controller chip, which this carrier does not have.
  boot.blacklistedKernelModules = [ "fusb301" ];

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
        # The uinput feature (virtual input devices) needs its module.
        INPUT_UINPUT = module;
      };
    }
  ];

  # JetPack is NVIDIA's: the CUDA libraries and their tools are unfree.
  nixpkgs.config.allowUnfree = true;
  # L4T firmware comes from bresilla/devices, and JetPack's own recipe never runs.
  nixpkgs.overlays = [
    (_: prev: {
      nvidia-jetpack = prev.nvidia-jetpack // { l4t-firmware = firmwares.nvidia-l4t-firmware; };
    })
  ];

  # The Jetson UEFI firmware on the module's QSPI starts systemd-boot from the NVMe.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
