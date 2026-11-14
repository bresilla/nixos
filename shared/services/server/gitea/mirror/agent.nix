# Host side of the git mirror: ssh-tpm-agent with a key made inside this machine's
# TPM. The key never leaves the TPM; containers get only the agent's socket, and
# only the group given here may use it.
{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.gitMirrorAgent;
  socket = "${cfg.socketDir}/agent.sock";
in {
  options.bresilla.services.gitMirrorAgent = {
    enable = lib.mkEnableOption "an SSH agent for the git mirror, its key in the TPM";
    keyDir = lib.mkOption {
      type = lib.types.strMatching "/var/lib/[A-Za-z0-9._-]+";
      default = "/var/lib/git-mirror";
      description = "Where the TPM-sealed key (*.tpm) is, made with ssh-tpm-keygen.";
    };
    socketDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/git-mirror-agent";
      description = "Directory of the agent's socket, bound into the container.";
    };
    gid = lib.mkOption {
      type = lib.types.int;
      description = "Host gid allowed to use the socket: the container's agent group, shifted.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Gives the tss group /dev/tpmrm0.
    security.tpm2.enable = true;
    users.users.git-mirror-agent = { isSystemUser = true; group = "git-mirror-agent"; };
    users.groups.git-mirror-agent = { };
    users.groups.git-mirror-socket.gid = cfg.gid;
    # Made at boot, before any container, and kept across agent restarts so the
    # container's bind of it stays the same directory.
    systemd.tmpfiles.rules = [ "d ${cfg.socketDir} 0750 git-mirror-agent git-mirror-socket -" ];

    systemd.services.git-mirror-agent = {
      description = "SSH agent of the git mirror (key in the TPM)";
      wantedBy = [ "multi-user.target" ];
      environment.HOME = cfg.keyDir;
      serviceConfig = {
        User = "git-mirror-agent";
        # The socket's group, so the container's agent group may connect.
        Group = "git-mirror-socket";
        SupplementaryGroups = [ "tss" ];
        StateDirectory = lib.removePrefix "/var/lib/" cfg.keyDir;
        StateDirectoryMode = "0700";
        ExecStartPre = "${pkgs.coreutils}/bin/rm -f ${socket}";
        ExecStart = "${pkgs.ssh-tpm-agent}/bin/ssh-tpm-agent -l ${socket} --key-dir ${cfg.keyDir}";
        Restart = "always";
        RestartSec = 5;
        UMask = "0007";
        DevicePolicy = "closed";
        DeviceAllow = [ "/dev/tpmrm0 rw" ];
        ReadWritePaths = [ cfg.socketDir ];
        PrivateNetwork = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectProc = "invisible";
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        NoNewPrivileges = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" ];
      };
    };
  };
}
