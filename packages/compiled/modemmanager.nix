{ modemmanager, libqmi, fetchgit }:

# Upstream main: nixpkgs' 1.24.2 lacks XMM7360 RPC support (T480) and recent
# QRTR fixes (FP6). 1.26 is not released yet; bump these pins together.
let
  qmi = libqmi.overrideAttrs {
    version = "1.39.1-unstable-2026-10-11";
    src = fetchgit {
      url = "https://gitlab.freedesktop.org/mobile-broadband/libqmi.git";
      rev = "d9e8af5cae7fdf9749baf87606568d3af4d03082";
      hash = "sha256-SeT/FPA1f87n2qyPCDC6vLGNT4XO7ii4g1ipffH8P1s=";
    };
  };
in
(modemmanager.override { libqmi = qmi; }).overrideAttrs (old: {
  version = "1.25.95-unstable-2026-10-05";
  src = fetchgit {
    url = "https://gitlab.freedesktop.org/mobile-broadband/ModemManager.git";
    rev = "7f0bf17ab518cd78925cf7e53cc0d5c42f88b41a";
    hash = "sha256-HXi6Bn445ZuPj0Dlp9BO4LPXHRnSjML+d6v67HDOvF0=";
  };
  # As separate modules, shared-mtk calls into shared-fibocom without linking it, so the
  # MTK and rolling plugins fail to load (undefined symbol). Built in, they share one binary.
  mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dbuiltin_plugins=true" ];
})
