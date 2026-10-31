{ pkgs, firmwares, ... }:
let
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
  hardware.firmware = [ firmwares.fp6-audio-firmware ];
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
