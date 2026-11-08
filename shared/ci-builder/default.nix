# `ci-builder`: makes any Linux machine with Nix and systemd a builder for
# build.bresilla.com, with emulation for the architectures it lacks.
{ nixpkgs, system }:
let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = pkgs.lib;
  hive = import ./hive.nix;
  emulated = builtins.filter (s: s != system) hive.systems;
  # Static qemu is cached and links only on x86_64; elsewhere the dynamic one is
  # used, with its libraries added to the build sandbox.
  static = system == "x86_64-linux";
  # NixOS knows each architecture's ELF magic.
  registrations = (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [{
      boot.isContainer = true;
      boot.binfmt.emulatedSystems = emulated;
      boot.binfmt.preferStaticEmulators = static;
      system.stateVersion = "26.05";
    }];
  }).config.boot.binfmt.registrations;
  interpreter = name: r:
    if static then r.interpreter else "${pkgs.qemu-user}/bin/qemu-${(lib.systems.elaborate name).qemuArch}";
  binfmt = pkgs.writeText "nix-ci-builder.conf" (lib.concatStrings (lib.mapAttrsToList (name: r:
    ":nix-ci-${name}:M::${r.magicOrExtension}:${r.mask}:${interpreter name r}:F${lib.optionalString r.preserveArgvZero "P"}\n"
  ) registrations));
  # The dynamic qemu's closure, listed in a file the script reads into the sandbox paths.
  sandboxList = if static then "" else "${pkgs.closureInfo { rootPaths = [ pkgs.qemu-user ]; }}/store-paths";
in
pkgs.writeShellApplication {
  name = "ci-builder";
  runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.wireguard-tools ];
  text = ''
    BINFMT=${binfmt}
    PLATFORMS="${toString emulated}"
    SANDBOX_LIST="${sandboxList}"
    CI_KEY="${hive.ciKey}"
    HIVE_KEY="${hive.publicKey}"
    HIVE_ENDPOINT="${hive.endpoint}"
    HIVE_ADDRESS="${hive.address}"
    WG_QUICK=${pkgs.wireguard-tools}/bin/wg-quick
    TOOLS_PATH=${lib.makeBinPath [ pkgs.wireguard-tools pkgs.iproute2 pkgs.coreutils pkgs.gnugrep pkgs.gnused ]}
  '' + builtins.readFile ./ci-builder.sh;
}
