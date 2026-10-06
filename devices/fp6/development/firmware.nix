{ lib, stdenv, pil-squasher, src }:

stdenv.mkDerivation {
  pname = "fairphone-fp6-firmware";
  version = "unstable";
  inherit src;
  # Qualcomm firmware contains signed ELF data, not executable host programs.
  # Nix's usual ELF patching and stripping must never rewrite these blobs.
  dontFixup = true;
  buildPhase = ''
    $CC ${pil-squasher}/pil-squasher.c -o pil-squasher
    for file in *.mdt; do ./pil-squasher "''${file%.mdt}.mbn" "$file"; done
  '';
  installPhase = ''
    target="$out/lib/firmware/qcom/milos/fairphone/fp6"
    mkdir -p "$target" "$out/lib/firmware/qca" "$out/lib/firmware/postmarketos"
    cp adsp*.mbn cdsp*.mbn wpss.mbn ipa_fws.mbn modem.mbn gen80300_zap.mbn vpu20_2v.mbn *.jsn "$target/"
    cp -R modem_pr "$target/"
    cp msbtfw12.mbn msnv12.bin "$out/lib/firmware/qca/"
    cp gen80300_gmu.bin gen80300_sqe.fw "$out/lib/firmware/postmarketos/"
    chmod -R a+rX "$out"
  '';
  meta = {
    description = "Fairphone 6 firmware in the mainline kernel layout";
    license = lib.licenses.unfree;
    platforms = [ "aarch64-linux" ];
  };
}
