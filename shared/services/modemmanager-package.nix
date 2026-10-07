{ lib, pkgs, source, qmiSource }:
let
  sourceVersion = tree: builtins.head (builtins.match ".*\n  version: '([^']+)'.*"
    (builtins.readFile (tree + "/meson.build")));
  version = sourceVersion source;
  qmiVersion = sourceVersion qmiSource;
  qmi = if lib.versionAtLeast pkgs.libqmi.version qmiVersion then pkgs.libqmi
    else pkgs.libqmi.overrideAttrs { version = qmiVersion; src = qmiSource; };
in
  # Stable nixpkgs currently lacks XMM7360 RPC support and recent QRTR fixes.
  # The installer refreshes this upstream input along with the other software.
  if lib.versionAtLeast pkgs.modemmanager.version version then pkgs.modemmanager
  else (pkgs.modemmanager.override { libqmi = qmi; }).overrideAttrs {
    inherit version;
    src = source;
  }
