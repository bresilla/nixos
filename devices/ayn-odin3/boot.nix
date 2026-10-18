{ lib, pkgs, ... }:

let
  dtbs = pkgs.writeText "odin3-dtbs" (builtins.readFile ./kernel/dtbs);
  # ROCKNIX-ABL boots /KERNEL from a FAT partition: an Android header-v0 boot
  # image of gzip(Image) with Armada's DTBs appended, in Armada's order, for its
  # model picker. Geometry matches Armada's bootimg-args.
  kernelImage = pkgs.writeShellApplication {
    name = "odin3-kernel-image";
    runtimeInputs = with pkgs; [
      android-tools
      coreutils
      gzip
    ];
    text = ''
      toplevel=$1 out=$2
      init="$toplevel/init"
      cmdline="init=$init nixos.init=$init $(< "$toplevel/kernel-params")"
      if (( ''${#cmdline} > 512 )); then
        echo "odin3-kernel-image: command line is ''${#cmdline} bytes, over the 512-byte header field" >&2
        exit 1
      fi
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      gzip -n -c "$toplevel/kernel" > "$work/kernel.gz"
      while read -r name; do
        cat "$toplevel/dtbs/qcom/$name.dtb" >> "$work/kernel.gz"
      done < ${dtbs}
      mkbootimg --kernel "$work/kernel.gz" --ramdisk "$toplevel/initrd" \
        --base 0x10000000 --pagesize 2048 --kernel_offset 0x00008000 \
        --ramdisk_offset 0x06000000 --tags_offset 0x00000100 \
        --header_version 0 --os_version 12.0.0 --os_patch_level 2026-10 \
        --cmdline "$cmdline" --output "$out"
    '';
  };
in
{
  boot.loader.grub.enable = false;
  boot.loader.external = {
    enable = true;
    # Each switch rewrites /KERNEL for the new default generation and keeps the
    # previous one as KERNEL.BAK; renaming it back from any PC rolls back.
    installHook = pkgs.writeShellScript "odin3-install-kernel" ''
      set -euo pipefail
      # Bootloader hooks run with an empty PATH.
      export PATH=${lib.makeBinPath (with pkgs; [ coreutils diffutils util-linux ])}
      boot=/boot
      mountpoint -q "$boot" || {
        echo "odin3: $boot is not mounted; refusing to write /KERNEL" >&2
        exit 1
      }
      ${lib.getExe kernelImage} "$1" "$boot/.KERNEL.new"
      if [ -f "$boot/KERNEL" ] && ! cmp -s "$boot/KERNEL" "$boot/.KERNEL.new"; then
        cp -f "$boot/KERNEL" "$boot/KERNEL.BAK"
      fi
      sync
      mv -f "$boot/.KERNEL.new" "$boot/KERNEL"
      sync
    '';
  };

  systemd.tpm2.enable = false;
  boot.initrd.systemd = {
    enable = true;
    tpm2.enable = false;
    # The bootloader may append its own init=; nixos.init names the closure alone.
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

  system.build.odin3KernelImage = kernelImage;
}
