{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.system;
  # Deploy the released static nox binary rather than rebuilding the crate during
  # a system build/install (fast, and needs no crate source on the target).
  noxBin = pkgs.fetchurl {
    url = "https://github.com/bresilla/nixos/releases/download/v0.1.1/nox";
    hash = "sha256-XzkJJyPwLuRKky2Ijba4gmJ3UbChNLzVB3nxt2chNXI=";
  };
  nox = pkgs.runCommand "nox" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    install -Dm755 ${noxBin} $out/bin/nox
    wrapProgram $out/bin/nox --prefix PATH : ${lib.makeBinPath [ pkgs.disko ]}
  '';
in
{
  options.bresilla.programs.system = {
    enable = lib.mkEnableOption "system inspection and maintenance programs" // {
      default = true;
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = (with pkgs; [
        brightnessctl
        lsb-release
        lm_sensors
        pavucontrol
      ]) ++ [ nox ];
      description = "System-level tools installed on every host.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = cfg.packages;
  };
}
