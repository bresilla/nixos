{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.yubikey-agent;
in
{
  options.bresilla.services.yubikey-agent.enable =
    lib.mkEnableOption "yubikey-agent, an ssh-agent for YubiKeys (the YubiKey feature's gpg-agent also serves SSH)";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.yubikey-agent ];
    systemd.user.services.yubikey-agent = {
      description = "Seamless ssh-agent for YubiKeys";
      documentation = [ "https://filippo.io/yubikey-agent" ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.yubikey-agent}/bin/yubikey-agent -l %t/yubikey-agent/yubikey-agent.sock";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        IPAddressDeny = "any";
        RestrictAddressFamilies = "AF_UNIX";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallFilter = [ "@system-service" "~@privileged @resources" ];
        SystemCallErrorNumber = "EPERM";
        SystemCallArchitectures = "native";
        NoNewPrivileges = true;
        KeyringMode = "private";
        UMask = "0177";
        RuntimeDirectory = "yubikey-agent";
      };
    };
  };
}
