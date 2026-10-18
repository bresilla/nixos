{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.decky;
  stateDir = "/var/lib/decky-loader";
  # Decky's own ARM64 build (PyInstaller); nix-ld runs it unpatched. 3.3 is the
  # first release with one.
  loader = pkgs.fetchurl {
    url = "https://github.com/SteamDeckHomebrew/decky-loader/releases/download/v3.3.0-pre1/PluginLoader-arm64";
    hash = "sha256-Kk6GRewgzNAfSNlxIaTlSKXaKZcALHcsp/BMc4D3f4M=";
    executable = true;
  };
in
{
  options.bresilla.programs.decky.enable =
    lib.mkEnableOption "Decky Loader, the plugin system for Steam's gaming mode";

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isAarch64) {
    programs.nix-ld.enable = true;
    # Created before the service, which starts in services/.
    systemd.tmpfiles.settings.decky-loader = lib.genAttrs [
      stateDir
      "${stateDir}/plugins"
      "${stateDir}/services"
    ] (_: {
      d = {
        user = config.bresilla.user.name;
        group = config.bresilla.user.name;
        mode = "0755";
      };
    });
    # Root, as Decky requires; it runs plugins as the user who owns Steam.
    systemd.services.decky-loader = {
      description = "Decky Loader for Steam";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        UNPRIVILEGED_USER = config.bresilla.user.name;
        UNPRIVILEGED_PATH = stateDir;
        PRIVILEGED_PATH = stateDir;
        PLUGIN_PATH = "${stateDir}/plugins";
        LOG_LEVEL = "INFO";
      };
      # Decky looks up the system Python's paths for plugin backends.
      path = [ pkgs.python3 ];
      serviceConfig = {
        ExecStart = loader;
        WorkingDirectory = "${stateDir}/services";
        Restart = "always";
        KillMode = "process";
        TimeoutStopSec = 15;
      };
    };
  };
}
