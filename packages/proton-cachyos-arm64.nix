{ stdenvNoCC, fetchurl, perl }:

# Windows games: Wine ARM64EC with FEX, with Armada's DXVK feature probe.
let
  protonName = "proton-cachyos-11.0-arm64";
in
stdenvNoCC.mkDerivation {
  pname = "proton-cachyos-arm64";
  version = "11.0-20261005-slr";
  src = fetchurl {
    url = "https://github.com/CachyOS/proton-cachyos/releases/download/cachyos-11.0-20261005-slr/proton-cachyos-11.0-20261005-slr-arm64.tar.xz";
    hash = "sha256-5ZtkbnPeSvIf8vbHlbKOe2yIkhSzxtr45lpWY0zQbDc=";
  };
  nativeBuildInputs = [ perl ];
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;
  installPhase = ''
    tool=$out/share/steam/compatibilitytools.d/${protonName}
    mkdir -p "$tool"
    cp -r . "$tool"
    substituteInPlace "$tool/proton" \
      --replace-fail "MODERN_DXVK_FEATURES = ['descriptorIndexing']" \
        "MODERN_DXVK_FEATURES = ['descriptorIndexing', 'storageBuffer8BitAccess']"
    perl -0pi \
      -e 's/("display_name"\s+)"[^"]+"/$1"Proton 11.0 CachyOS (ARM64)"/;' \
      -e 's/("compat_tools"\s*\{\s*)"[^"]+"/$1"${protonName}"/' \
      "$tool/compatibilitytool.vdf"
  '';
  meta.platforms = [ "aarch64-linux" ];
}
