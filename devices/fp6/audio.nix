{ pkgs, ... }:
let
  topologySource = pkgs.fetchgit {
    url = "https://forgejo.catcrafts.net/Catcrafts/audioreach-topology.git";
    rev = "76e10781fcc16a3fd8dfd0278ad9dc307ed29871";
    hash = "sha256-Z8RI1qMs3kyBZdxTCJ5YLBzJe8+QH56XSplBA0OzKMo=";
  };
  firmwareSource = pkgs.fetchFromGitHub {
    owner = "FairBlobs";
    repo = "FP6-firmware";
    rev = "e58a5be8fa0fb6bc5a5f2e29cc01c036ccf75710";
    hash = "sha256-CkPtCerCH/7+atDjsLmHRoDDyjCVP6U7u8cCw75iv/E=";
  };
  audioFirmware =
    pkgs.runCommand "fp6-audio-firmware"
      {
        nativeBuildInputs = [
          pkgs.m4
          pkgs.alsa-utils
        ];
        meta.license = pkgs.lib.licenses.unfree;
      }
      ''
        mkdir -p "$out/lib/firmware/qcom/milos/fairphone/fp6"
        m4 -I ${topologySource} ${topologySource}/MILOS-Fairphone-Gen6.m4 > fp6.conf
        alsatplg -c fp6.conf -o "$out/lib/firmware/qcom/milos/MILOS-Fairphone-Gen6-tplg.bin"
        cp ${firmwareSource}/aw882xx_acf.bin \
          "$out/lib/firmware/qcom/milos/fairphone/fp6/aw88261_acf.bin"
      '';
  ucm = pkgs.runCommand "fp6-alsa-ucm" { } ''
    cp -r ${pkgs.alsa-ucm-conf}/share/alsa/ucm2 "$out"
    chmod -R u+w "$out"
    mkdir -p "$out/Qualcomm/milos/Fairphone-Gen6" "$out/conf.d/milos"
    cp ${./audio/MILOS-Fairphone-Gen6.conf} "$out/Qualcomm/milos/Fairphone-Gen6/MILOS-Fairphone-Gen6.conf"
    cp ${./audio/HiFi.conf} "$out/Qualcomm/milos/Fairphone-Gen6/HiFi.conf"
    ln -s ../../Qualcomm/milos/Fairphone-Gen6/MILOS-Fairphone-Gen6.conf \
      "$out/conf.d/milos/MILOS-Fairphone-Gen6.conf"
  '';
in
{
  # Requires the audio drivers/device tree in development/flake.nix.
  # Normal software updates still reuse /etc/nixos/boot-hardware.json.
  hardware.firmware = [ audioFirmware ];
  environment.systemPackages = [ pkgs.alsa-utils ];
  environment.sessionVariables.ALSA_CONFIG_UCM2 = "${ucm}";
  systemd.user.services.wireplumber.environment.ALSA_CONFIG_UCM2 = "${ucm}";
  systemd.user.services.pipewire.environment.ALSA_CONFIG_UCM2 = "${ucm}";
}
