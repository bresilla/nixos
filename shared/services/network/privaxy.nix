{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.privaxy;
  # Not in nixpkgs; upstream's prebuilt headless binary only needs glibc.
  privaxy = pkgs.stdenv.mkDerivation rec {
    pname = "privaxy";
    version = "0.5.2";
    src = pkgs.fetchurl {
      url = "https://github.com/barre/privaxy/releases/download/v${version}/privaxy_nogui-${pkgs.stdenv.hostPlatform.parsed.cpu.name}-unknown-linux-gnu.zip";
      hash = {
        x86_64-linux = "sha256-YErmMMs43UGMjVIsT424lFhiBPkD61C4UoJZL3p4NbU=";
        aarch64-linux = "sha256-G35z6Rd9oZBvtnAvE31K5p9yHbAZAuDjdT2K+YoKx68=";
      }.${pkgs.stdenv.hostPlatform.system};
    };
    nativeBuildInputs = [ pkgs.unzip pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    sourceRoot = ".";
    installPhase = "install -Dm755 privaxy $out/bin/privaxy";
    meta.mainProgram = "privaxy";
  };
in
{
  options.bresilla.services.privaxy.enable =
    lib.mkEnableOption "the Privaxy tracker and advertisement blocker";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ privaxy ];
    systemd.user.services.privaxy = {
      description = "Privaxy tracker and advertisement blocker";
      documentation = [ "https://github.com/barre/privaxy" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = "${privaxy}/bin/privaxy";
        ExecReload = "${pkgs.coreutils}/bin/kill -SIGUSR1 $MAINPID";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
