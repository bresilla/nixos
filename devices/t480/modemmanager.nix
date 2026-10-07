{ lib, pkgs, ... }:
let
  # XMM7360 RPC support landed after the stable package in NixOS 26.05.
  # Drop this compatibility override automatically once nixpkgs catches up.
  manager = pkgs.modemmanager.overrideAttrs (old: {
    version = "1.25.95";
    src = pkgs.fetchFromGitLab {
      domain = "gitlab.freedesktop.org";
      owner = "mobile-broadband";
      repo = "ModemManager";
      rev = "1.25.95-dev";
      hash = "sha256-xyb9LTkuJyTqt0yWDDJTYiICFVFJ5SqRlnOdrhrL2Ps=";
    };
  });
in {
  networking.modemmanager.package =
    if lib.versionAtLeast pkgs.modemmanager.version "1.25.95"
    then pkgs.modemmanager else manager;
}
