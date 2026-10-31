{ config, lib, pkgs, bresilla, ... }:

let
  cfg = config.bresilla.system.remote.rdp;
  ssh = config.bresilla.system.remote.ssh;
  user = config.bresilla.user.name;
  # Pinned in the bresilla cache; null until the updater has fetched the pin.
  inherit (bresilla) hypr-rdp;
  tty = "tty${toString cfg.vt}";
  # Started by hand over SSH; never at boot.
  command = pkgs.writeShellScriptBin "hypr-remote" ''
    set -eu
    case "''${1:-}" in
      start)
        systemctl start hypr-remote.service
        echo "Remote Hyprland session started on ${tty}; RDP listens on port ${toString cfg.port}."
        ;;
      stop)
        systemctl stop hypr-remote.service
        ;;
      status)
        systemctl status --no-pager hypr-remote.service
        ;;
      *)
        echo "usage: hypr-remote start|stop|status" >&2
        exit 2
        ;;
    esac
  '';
in
{
  options.bresilla.system.remote.ssh.enable = lib.mkEnableOption "the OpenSSH server";

  options.bresilla.system.remote.rdp = {
    enable = lib.mkEnableOption "an on-demand Hyprland session served over RDP";
    vt = lib.mkOption {
      type = lib.types.ints.between 2 12;
      default = 7;
      description = "Virtual console the remote session runs on.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3389;
      description = "RDP port; the firewall only admits it on trusted VPN interfaces.";
    };
    autoStart = lib.mkEnableOption "starting the remote session at boot and restarting it when it ends";
  };

  config = lib.mkMerge [
  # Keys only, never root; the server itself runs where a profile enables it.
  {
    services.openssh.settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  }

  (lib.mkIf ssh.enable { services.openssh.enable = true; })

  # Gitea's SSH on hive, reached from anywhere through the Cloudflare tunnel.
  {
    programs.ssh.extraConfig = ''
      Host git.bresilla.com
        User git
        ProxyCommand ${pkgs.cloudflared}/bin/cloudflared access ssh --hostname ssh-git.bresilla.com
    '';
  }

  (lib.mkIf cfg.enable {
    environment.systemPackages = [ command ];

    # A real logind session on its own console, so Hyprland gets the GPU.
    systemd.services.hypr-remote = {
      description = "Hyprland session for remote desktop";
      wantedBy = lib.mkIf cfg.autoStart [ "multi-user.target" ];
      after = [ "systemd-user-sessions.service" "getty@${tty}.service" ];
      conflicts = [ "getty@${tty}.service" ];
      environment = {
        XDG_SESSION_TYPE = "wayland";
        XDG_SESSION_CLASS = "user";
        XDG_SEAT = "seat0";
        XDG_VTNR = toString cfg.vt;
        # Lets the hypr-rdp user service tell this session from a local login.
        HYPR_REMOTE = "1";
        # A login's PATH rather than systemd's, so the session finds setuid sudo first.
        PATH = lib.mkForce (lib.concatStringsSep ":" [
          "/run/wrappers/bin"
          "/etc/profiles/per-user/${user}/bin"
          "/nix/var/nix/profiles/default/bin"
          "/run/current-system/sw/bin"
        ]);
      };
      serviceConfig = {
        User = user;
        PAMName = "login";
        TTYPath = "/dev/${tty}";
        TTYReset = true;
        TTYVHangup = true;
        TTYVTDisallocate = true;
        StandardInput = "tty-fail";
        # logind only hands the GPU to the session on the foreground console.
        ExecStartPre = "+${pkgs.kbd}/bin/chvt ${toString cfg.vt}";
        ExecStopPost = "+${pkgs.kbd}/bin/chvt 1";
        Restart = if cfg.autoStart then "always" else "no";
        RestartSec = 5;
        UtmpIdentifier = tty;
        UtmpMode = "user";
        ExecStart = "${pkgs.uwsm}/bin/uwsm start -e -D Hyprland hyprland.desktop";
      };
    };

    # hypr-rdp runs only inside the remote session. Logins are one-time signatures by
    # the SSH keys that may already log in here; no RDP password exists.
    systemd.user.services.hypr-rdp = {
      description = "RDP server for the remote Hyprland session";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      unitConfig.ConditionEnvironment = "HYPR_REMOTE=1";
      serviceConfig = {
        ExecStart = "${hypr-rdp}/bin/hypr-rdp --auth-mode ssh --authorized-keys /etc/ssh/authorized_keys.d/${user} --bind 0.0.0.0:${toString cfg.port} --egfx-codec avc420 --fps 60";
        Restart = "on-failure";
      };
    };

    # Passwordless start and stop over SSH; "" forbids other arguments.
    security.sudo.extraRules = [
      {
        users = [ user ];
        commands = map (action: {
          command = "/run/current-system/sw/bin/hypr-remote ${action}";
          options = [ "NOPASSWD" ];
        }) [ "start" "stop" "status" ];
      }
    ];
  })
  ];
}
