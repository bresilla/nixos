# Armada's Odin 3 kernel: kernel.org stable, Armada's patch series and device trees.
# Its nixpkgs is pinned apart from the system's, so updates never rebuild the kernel.
{
  buildSystem ? "aarch64-linux",
}:

let
  version = "7.2.6";
  nixpkgsSrc = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/2c423e03bbafcff28bfadc6781a4a8257f205cb5.tar.gz";
    sha256 = "0sncav0zwd301731dh1pqdfgwiak5af6b5gg178wy0zcrdsidpkn";
  };
  pkgs =
    if buildSystem == "aarch64-linux" then
      import nixpkgsSrc { system = "aarch64-linux"; }
    else
      import nixpkgsSrc {
        localSystem = buildSystem;
        crossSystem = "aarch64-linux";
      };
  inherit (pkgs) lib;

  armadaRev = "2fdf06ebba892e2874f874d6202250d63433bf4b";
  armada =
    paths: hash:
    pkgs.fetchFromGitHub {
      owner = "armada-os";
      repo = "armada";
      rev = armadaRev;
      sparseCheckout = paths;
      inherit hash;
    };
  armadaKernel = armada [ "packages/kernel" ] "sha256-BBIo6x4CaDhDuvHDF9UczLAJTGCbdsRWJNp5BnaUkX4=";
  armadaFirmware = armada [ "system_files/usr/lib/firmware" ] "sha256-h/IFkwWVrU4bT0LnUyTuwOz5NdnD7cJoacFsYb9+R/M=";

  # Patched tree, as Armada's scripts/build-kernel.sh prepares it.
  source = pkgs.buildPackages.stdenvNoCC.mkDerivation {
    pname = "linux-odin3-source";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${version}.tar.xz";
      hash = "sha256-A5rvhPKwmUrto/T8/D0C7J16m7uQIOomTEP0Rshg9gY=";
    };
    kernel = "${armadaKernel}/packages/kernel";
    buildPhase = ''
      runHook preBuild
      while IFS= read -r line; do
        line="''${line%%#*}"
        read -r name _ <<< "$line" || true
        [ -n "''${name:-}" ] || continue
        echo "applying $name"
        patch -p1 --batch --forward -F0 --no-backup-if-mismatch --quiet < "$kernel/patches/$name"
      done < "$kernel/patches/series"
      qcom=arch/arm64/boot/dts/qcom
      cp "$kernel"/dts/*.dts "$kernel"/dts/*.dtsi "$qcom/"
      chmod -R u+w "$qcom"
      for p in "$kernel"/dts/*.patch; do
        patch -p1 -F0 --no-backup-if-mismatch --quiet < "$p"
      done
      {
        echo
        echo "# armada-kernel DTBs"
        for dts in "$kernel"/dts/*.dts; do
          echo "dtb-\$(CONFIG_ARCH_QCOM) += $(basename "$dts" .dts).dtb"
        done
      } >> "$qcom/Makefile"
      # Without a default the port starts as a device and becomes a host only once
      # UCSI answers, which it often fails to; the root drive sits on this port.
      echo '&usb { role-switch-default-mode = "host"; };' >> "$qcom/cq8725s-ayn-odin3.dts"
      runHook postBuild
    '';
    installPhase = "cp -r . $out";
    dontFixup = true;
  };

  # Regenerates kernel.config: defconfig, then Armada's fragment and ours
  # (what NixOS and a USB root need), as Armada merges it.
  config = pkgs.stdenv.mkDerivation {
    pname = "linux-odin3-config";
    inherit version;
    src = source;
    depsBuildBuild = [ pkgs.buildPackages.stdenv.cc ];
    nativeBuildInputs = with pkgs.buildPackages; [
      bc
      bison
      flex
      perl
      python3
      pahole
    ];
    makeFlags = [
      "ARCH=arm64"
      "CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix}"
    ];
    buildPhase = ''
      runHook preBuild
      patchShebangs scripts
      make $makeFlags defconfig
      cat ${armadaKernel}/packages/kernel/config/armada-kernel.config.overrides ${./kernel.fragment} \
        | sed -E '/^[[:space:]]*CONFIG_[A-Z0-9_]+=/ s/[[:space:]]*#.*$//' > fragment
      ARCH=arm64 CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix} \
        bash scripts/kconfig/merge_config.sh -m .config fragment
      make $makeFlags olddefconfig
      missing=0
      while IFS= read -r requested; do
        case "$requested" in
          CONFIG_*=y) grep -qx "$requested" .config || { echo "lost: $requested"; missing=1; } ;;
        esac
      done < fragment
      [ "$missing" = 0 ]
      runHook postBuild
    '';
    installPhase = "cp .config $out";
  };

  configfile = ./kernel.config;
  parseLine =
    line:
    let
      match = builtins.match "(CONFIG_[A-Za-z0-9_]+)=(.*)" line;
    in
    lib.optional (match != null) {
      name = builtins.elemAt match 0;
      value = lib.removePrefix "\"" (lib.removeSuffix "\"" (builtins.elemAt match 1));
    };

  kernel = pkgs.linuxKernel.manualConfig {
    inherit version configfile;
    src = source;
    modDirVersion = version;
    config = builtins.listToAttrs (
      lib.concatMap parseLine (lib.splitString "\n" (builtins.readFile configfile))
    );
  };

  # Only the Odin 3's share of Armada's firmware; linux-firmware supplies the rest.
  firmware = pkgs.buildPackages.runCommand "odin3-firmware" { } ''
    src=${armadaFirmware}/system_files/usr/lib/firmware
    dst=$out/lib/firmware
    mkdir -p $dst/qcom/sm8750
    cp -r --no-preserve=mode $src/ath12k $src/qca $dst/
    cp -r --no-preserve=mode $src/qcom/vpu $src/qcom/gen80000_* $dst/qcom/
    cp -r --no-preserve=mode $src/qcom/sm8750/ayn $src/qcom/sm8750/gen80000_zap.mbn $src/qcom/sm8750/SM8750-AYN-tplg.bin $dst/qcom/sm8750/
  '';
in
{
  inherit
    source
    config
    kernel
    firmware
    ;
  dtbs = lib.splitString "\n" (lib.trim (builtins.readFile ./dtbs));
}
