{
  config,
  lib,
  pkgs,
  fp6BootArtifacts,
  fp6BuildPkgs,
  ...
}:

let
  installed =
    let
      artifacts = fp6BootArtifacts;
      # Context makes these existing outputs dependencies of the new generation,
      # retaining them through GC without introducing a kernel build derivation.
      storeOutput =
        path:
        assert builtins.match "/nix/store/[a-z0-9]{32}-[^/]+" path != null;
        builtins.appendContext path {
          ${path} = {
            path = true;
          };
        };
      kernelConfig = artifacts.config // rec {
        isSet = name: builtins.hasAttr ("CONFIG_" + name) artifacts.config;
        getValue = name: artifacts.config.${"CONFIG_" + name} or null;
        isYes = name: getValue name == "y";
        isNo = name: getValue name == "n";
        isModule = name: getValue name == "m";
        isEnabled = name: isYes name || isModule name;
        isDisabled = name: !isSet name || isNo name;
      };
      kernel = lib.makeOverridable (
        {
          kernelPatches ? [ ],
          ...
        }:
        assert lib.assertMsg (
          kernelPatches == [ ]
        ) "Cannot patch the installed FP6 kernel during a software update.";
        {
          type = "derivation";
          name = "linux-${artifacts.version}";
          outPath = storeOutput artifacts.kernel;
          modules = {
            type = "derivation";
            outPath = storeOutput artifacts.modules;
          };
          inherit (artifacts) version modDirVersion features;
          inherit (pkgs) stdenv;
          config = kernelConfig;
          configfile = pkgs.writeText "installed-fp6-kernel-config" artifacts.configText;
          kernelOlder = lib.versionOlder artifacts.version;
          kernelAtLeast = lib.versionAtLeast artifacts.version;
          isZen = false;
          isLTS = false;
          dev = throw "Kernel headers require an explicit FP6 development build.";
        }
      ) { };
    in
    {
      inherit kernel;
      firmware = storeOutput artifacts.firmware;
      extraModules = map storeOutput (artifacts.extraModules or [ ]);
    };
  kernel = config.boot.kernelPackages.kernel;
  dtb = "${kernel}/dtbs/qcom/milos-fairphone-fp6.dtb";
  hostPkgs = fp6BuildPkgs.buildPackages;
  gpuFirmwarePaths = pkgs.runCommand "fp6-gpu-firmware-paths" { } ''
    mkdir -p "$out/lib/firmware/qcom"
    for file in gen80300_sqe.fw gen80300_gmu.bin; do
      ln -s ${installed.firmware}/lib/firmware/postmarketos/"$file" "$out/lib/firmware/qcom/$file"
    done
  '';
in
{
  imports = [ ./storage.nix ];
  boot.kernelPackages = pkgs.linuxPackagesFor installed.kernel;
  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = [
    installed.firmware
    gpuFirmwarePaths
  ];
  hardware.firmwareCompression = "none";
  boot.extraModulePackages = installed.extraModules;
  assertions = [
    {
      assertion = map toString config.boot.extraModulePackages == installed.extraModules;
      message = "The FP6 reuses its installed kernel. Build a matching kernel/module bundle explicitly for external modules.";
    }
  ];
  boot.initrd = {
    includeDefaultModules = false;
    compressor = "gzip";
    availableKernelModules = [
      "loop"
      "ext4"
      "panel-novatek-nt37705"
      "spi-geni-qcom"
    ];
    extraFirmwarePaths = [
      "qcom/gen80300_sqe.fw"
      "qcom/gen80300_gmu.bin"
      "qcom/milos/fairphone/fp6/gen80300_zap.mbn"
    ];
    systemd = {
      enable = true;
      tpm2.enable = false;
      extraBin.losetup = "${pkgs.util-linux}/bin/losetup";
      # The Android bootloader appends init=/init after the boot image command
      # line. A separate argument keeps the intended NixOS closure unambiguous.
      services.initrd-find-nixos-closure.script = lib.mkForce ''
        closure=
        for argument in $(< /proc/cmdline); do
          case "$argument" in
            nixos.init=*) closure="''${argument#nixos.init=}"; break ;;
          esac
        done
        case "$closure" in
          /nix/store/*/init) closure="''${closure%/init}" ;;
          *) echo 'Missing or invalid nixos.init boot argument' >&2; exit 1 ;;
        esac
        prepare_root="$(readlink "/sysroot$closure/prepare-root" || echo "$closure/prepare-root")"
        test -x "/sysroot$prepare_root"
        ln -s "$closure" /nixos-closure
        echo 'NEW_INIT=' > /etc/switch-root.conf
      '';

    };
  };
  boot.kernelModules = [ "libcomposite" ];
  systemd.tpm2.enable = false;
  boot.kernelParams = [
    "console=tty0"
    "console=ttyMSM0,115200"
  ];
  boot.loader.external = {
    enable = true;
    # Boot partition writes and A/B changes are deliberately external to activation.
    installHook = pkgs.writeShellScript "fp6-external-boot" ''
      echo "FP6 boot images must be built and installed separately."
    '';
  };
  systemd.services.fp6-usb-gadget = {
    description = "Fairphone 6 USB NCM networking";
    wantedBy = [ "multi-user.target" ];
    after = [ "sys-kernel-config.mount" ];
    requires = [ "sys-kernel-config.mount" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      gadget=/sys/kernel/config/usb_gadget/fp6
      mkdir -p "$gadget"
      # A repeated start must not rewrite descriptors of a bound gadget.
      if [ -n "$(cat "$gadget/UDC")" ]; then exit 0; fi
      echo 0x1d6b > "$gadget/idVendor"
      echo 0x0103 > "$gadget/idProduct"
      mkdir -p "$gadget/strings/0x409" "$gadget/configs/c.1/strings/0x409"
      echo fp6-nixos > "$gadget/strings/0x409/serialnumber"
      echo Fairphone > "$gadget/strings/0x409/manufacturer"
      echo 'NixOS FP6 USB networking' > "$gadget/strings/0x409/product"
      echo 'NCM networking' > "$gadget/configs/c.1/strings/0x409/configuration"
      mkdir -p "$gadget/functions/ncm.usb0"
      echo 02:00:00:00:06:01 > "$gadget/functions/ncm.usb0/dev_addr"
      echo 02:00:00:00:06:02 > "$gadget/functions/ncm.usb0/host_addr"
      if [ ! -L "$gadget/configs/c.1/ncm.usb0" ]; then
        ln -s "$gadget/functions/ncm.usb0" "$gadget/configs/c.1/ncm.usb0"
      fi
      for attempt in $(seq 1 30); do
        for controller in /sys/class/udc/*; do
          if [ -e "$controller" ]; then basename "$controller" > "$gadget/UDC"; exit 0; fi
        done
        sleep 1
      done
      echo 'No USB device controller became available' >&2
      exit 1
    '';
  };
  system.build.fp6BootImage =
    hostPkgs.runCommand "fp6-boot.img"
      {
        nativeBuildInputs = [
          hostPkgs.android-tools
          hostPkgs.gzip
        ];
      }
      ''
        gzip --no-name --stdout ${kernel}/Image > Image.gz
        mkbootimg --header_version 2 --kernel Image.gz \
          --ramdisk ${config.system.build.initialRamdisk}/initrd --dtb ${dtb} \
          --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
          --second_offset 0x00000000 --tags_offset 0x00000100 --dtb_offset 0x01f00000 \
          --pagesize 4096 --os_version 99.87.36 --os_patch_level 2099-12-31 \
          --cmdline ${lib.escapeShellArg "init=${config.system.build.toplevel}/init nixos.init=${config.system.build.toplevel}/init ${lib.concatStringsSep " " config.boot.kernelParams}"} \
          --output boot.img
        # The stock vbmeta partition chains to metadata inside boot. Replace the
        # entire 96 MiB image so an older AVB footer cannot reference overwritten
        # metadata. Unsigned images require the already-unlocked bootloader.
        avbtool add_hash_footer --image boot.img --partition_name boot \
          --partition_size $((96 * 1024 * 1024)) --algorithm NONE --salt ""
        avbtool verify_image --image boot.img
        mv boot.img "$out"
      '';
}
