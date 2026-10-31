{ stdenv, fetchurl, dpkg, autoPatchelfHook }:

# Only the daemon from Ubiquiti's .deb; it finds wg, wg-quick and wireguard-go beside itself.
stdenv.mkDerivation rec {
  pname = "wifiman-desktopd";
  version = "1.3.0";
  src = fetchurl {
    url = "https://desktop.wifiman.com/wifiman-desktop-${version}-amd64.deb";
    hash = "sha256-K7dbc8CS5DWSu9QIQWKPIiAAvqlaKDiar+hK2vJ5zXg=";
  };
  nativeBuildInputs = [ dpkg autoPatchelfHook ];
  unpackPhase = "dpkg-deb -x $src .";
  installPhase = ''
    mkdir -p $out/lib
    cp -r usr/lib/wifiman-desktop $out/lib/
    chmod +x $out/lib/wifiman-desktop/wg-quick
  '';
  meta.platforms = [ "x86_64-linux" ];
}
