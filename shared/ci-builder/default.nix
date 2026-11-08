# `ci-builder`: makes any Linux machine with Nix and systemd a builder for
# build.bresilla.com, with emulation for the architectures it lacks.
{ nixpkgs, system }:
let
  pkgs = nixpkgs.legacyPackages.${system};
  hive = import ./hive.nix;
  emulated = builtins.filter (s: s != system) [ "x86_64-linux" "aarch64-linux" "riscv64-linux" ];
  # NixOS knows each architecture's ELF magic; its static qemu works outside NixOS.
  registrations = (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [{
      boot.isContainer = true;
      boot.binfmt.emulatedSystems = emulated;
      boot.binfmt.preferStaticEmulators = true;
      system.stateVersion = "26.05";
    }];
  }).config.boot.binfmt.registrations;
  binfmt = pkgs.writeText "nix-ci-builder.conf" (pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList (name: r:
    ":nix-ci-${name}:M::${r.magicOrExtension}:${r.mask}:${r.interpreter}:F${pkgs.lib.optionalString r.preserveArgvZero "P"}\n"
  ) registrations));
in
pkgs.writeShellApplication {
  name = "ci-builder";
  runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.wireguard-tools ];
  text = ''
    BINFMT=${binfmt}
    PLATFORMS="${toString emulated}"
    CI_KEY="${hive.ciKey}"
    HIVE_KEY="${hive.publicKey}"
    HIVE_ENDPOINT="${hive.endpoint}"
    HIVE_ADDRESS="${hive.address}"
    WG_QUICK=${pkgs.wireguard-tools}/bin/wg-quick
    TOOLS_PATH=${pkgs.lib.makeBinPath [ pkgs.wireguard-tools pkgs.iproute2 pkgs.coreutils pkgs.gnugrep pkgs.gnused ]}
  '' + builtins.readFile ./ci-builder.sh;
}
