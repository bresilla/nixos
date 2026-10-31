{ lib, pkgs, ... }:
let
  # Armada's UCM for the Odin 3; the topology and amplifier firmware are in
  # odin3-firmware, from bresilla/devices.
  armada = pkgs.fetchFromGitHub {
    owner = "armada-os";
    repo = "armada";
    rev = "2fdf06ebba892e2874f874d6202250d63433bf4b";
    sparseCheckout = [
      "system_files/usr/share/alsa/ucm2/AYN/Odin3"
      "system_files/usr/share/alsa/ucm2/conf.d/sm8750"
    ];
    hash = "sha256-dPkloPKTO01CMg6Spihncy7OV5rM40wu7STwRxgDuQw=";
  };
  # alsa-lib finds UCM through ALSA_CONFIG_UCM2, so no ALSA package is rebuilt.
  ucm = pkgs.runCommand "odin3-alsa-ucm" { } ''
    mkdir -p $out/share/alsa
    cp -r --no-preserve=mode ${pkgs.alsa-ucm-conf}/share/alsa/ucm2 $out/share/alsa/ucm2
    cp -r --no-preserve=mode ${armada}/system_files/usr/share/alsa/ucm2/. $out/share/alsa/ucm2/
  '';
  ucmPath = "${ucm}/share/alsa/ucm2";
in
{
  environment.variables.ALSA_CONFIG_UCM2 = ucmPath;
  systemd.user.services.pipewire.environment.ALSA_CONFIG_UCM2 = ucmPath;
  systemd.user.services.wireplumber.environment.ALSA_CONFIG_UCM2 = ucmPath;

  # Armada's buffer sizes for the AudioReach DSP.
  services.pipewire.extraConfig = {
    pipewire."99-odin3-buffers"."context.properties"."default.clock.min-quantum" = 1024;
    pipewire-pulse."99-odin3-buffers"."pulse.properties" = {
      "pulse.min.req" = "512/48000";
      "pulse.min.quantum" = "512/48000";
      "pulse.min.frag" = "512/48000";
    };
  };
}
