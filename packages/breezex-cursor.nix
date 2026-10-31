{ stdenvNoCC, fetchurl }:

# The cursor Hyprland is told to use; nixpkgs does not package it.
stdenvNoCC.mkDerivation {
  pname = "breezex-cursor";
  version = "2.0.1";
  src = fetchurl {
    url = "https://github.com/ful1e5/BreezeX_Cursor/releases/download/v2.0.1/BreezeX-Black.tar.xz";
    hash = "sha256-dzt1UjdIFzQJ7mIoQbD3Sx6AYXpcWz3LtTp6w9BswjM=";
  };
  installPhase = ''
    mkdir -p $out/share/icons/BreezeX-Black
    cp -r . $out/share/icons/BreezeX-Black
  '';
}
