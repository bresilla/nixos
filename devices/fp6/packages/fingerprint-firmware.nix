{
  lib,
  runCommand,
  fetchurl,
  makeWrapper,
  runtimeShell,
  coreutils,
  util-linux,
  gawk,
  gnused,
  gnugrep,
}:
let
  extractor = fetchurl {
    url = "https://forgejo.catcrafts.net/Catcrafts/fp6-img/raw/commit/f98289ce013c2945cd986d76ea8ca6a7517ba914/aports/device/fp6-vendor-blobs/fp6-vendor-blobs-extract";
    hash = "sha256-XovCN4Gezk+tf7hVGLENnqysD2FHlelgVvPZmv1wSG0=";
  };
in
runCommand "fp6-fingerprint-firmware"
  {
    nativeBuildInputs = [ makeWrapper ];
  }
  ''
    mkdir -p "$out/libexec" "$out/share/manifest.d" "$out/bin"
    cp ${extractor} "$out/libexec/extract"
    substituteInPlace "$out/libexec/extract" \
      --replace-fail 'MANIFEST_DIR=/usr/share/fp6-vendor-blobs/manifest.d' \
      "MANIFEST_DIR=$out/share/manifest.d"
    # The phone's own signed trustlet is reconstructed from read-only mounts.
    # This manifest never mounts or changes fingerprint template storage.
    echo 'mbn modem_a,modem_b image focal64 /var/lib/fingerprintd/focal64.mbn -' \
      > "$out/share/manifest.d/fingerprint.manifest"
    makeWrapper ${runtimeShell} "$out/bin/fp6-fingerprint-firmware" \
      --add-flags "-u $out/libexec/extract" \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          util-linux
          gawk
          gnused
          gnugrep
        ]
      }
  ''
