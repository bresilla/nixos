self: { config, lib, pkgs, ... }:
let
  cfg = config.services.muros-forge;
  format = pkgs.formats.toml { };
  configFile = format.generate "muros-forge.toml" cfg.settings;
in {
  options.services.muros-forge = {
    enable = lib.mkEnableOption "muros-forge, the Gitea and GitHub integration for muros";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.muros;
      description = "Package containing muros-forge.";
    };
    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = "muros-forge TOML settings. Secrets are file references, usually under /run/credentials/muros-forge.service/.";
    };
    credentials = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Credential names mapped to runtime source files for LoadCredential.";
    };
  };
  config = lib.mkIf cfg.enable {
    services.muros-forge.settings.state-directory = lib.mkDefault "/var/lib/muros-forge";
    systemd.services.muros-forge = {
      description = "muros-forge integration";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/muros-forge --config ${configFile}";
        DynamicUser = true;
        StateDirectory = "muros-forge";
        LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") cfg.credentials;
        Restart = "always";
        RestartSec = 2;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        CapabilityBoundingSet = "";
        MemoryMax = "1G";
        TasksMax = 256;
      };
    };
  };
}
