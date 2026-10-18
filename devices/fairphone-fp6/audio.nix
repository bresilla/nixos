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
  # Requires the audio drivers and device tree of the kernel in kernel/.
  hardware.firmware = [ audioFirmware ];
  environment.systemPackages = [ pkgs.alsa-utils ];
  environment.sessionVariables.ALSA_CONFIG_UCM2 = "${ucm}";
  systemd.user.services.wireplumber.environment.ALSA_CONFIG_UCM2 = "${ucm}";
  systemd.user.services.pipewire.environment.ALSA_CONFIG_UCM2 = "${ucm}";

  # The AudioReach PCM requires at least two channels, but this microphone
  # occupies FL only. Expose that channel as mono so applications neither
  # receive a silent right channel nor lose gain when downmixing it.
  services.pipewire.extraConfig.pipewire."91-fp6-microphone"."context.modules" = [
    {
      name = "libpipewire-module-loopback";
      args = {
        "capture.props" = {
          "audio.position" = [ "FL" ];
          "stream.dont-remix" = true;
          "target.object" = "alsa_input.platform-sound.HiFi__Mic__source";
          "node.passive" = true;
        };
        "playback.props" = {
          "node.name" = "fp6_microphone";
          "node.description" = "Handset microphone (bottom edge)";
          "device.icon-name" = "audio-input-microphone";
          "media.class" = "Audio/Source";
          "audio.position" = [ "MONO" ];
          "priority.session" = 2000;
        };
      };
    }
  ];
  services.pipewire.wireplumber.extraConfig."51-fp6-microphone"."monitor.alsa.rules" = [
    {
      matches = [ { "node.name" = "alsa_input.platform-sound.HiFi__Mic__source"; } ];
      actions.update-props = {
        "node.hidden" = true;
        "priority.session" = 0;
      };
    }
  ];
}
