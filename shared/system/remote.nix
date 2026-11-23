{ config, lib, pkgs, bresilla, ... }:

let
  cfg = config.bresilla.system.remote.rdp;
  ssh = config.bresilla.system.remote.ssh;
  user = config.bresilla.user.name;
  # Pinned in the bresilla cache; null until the updater has fetched the pin.
  inherit (bresilla) hypr-rdp;
  tty = "tty${toString cfg.vt}";
  # hypr-rdp on the remote session's Hyprland, whichever is running now. The user's
  # manager outlives a restarted session, so this ends with that Hyprland and systemd
  # starts it again on the new one.
  follow = pkgs.writeShellApplication {
    name = "hypr-rdp-follow";
    runtimeInputs = [ config.programs.hyprland.package pkgs.jq pkgs.coreutils pkgs.gnused pkgs.systemd ];
    text = ''
      # The remote session is the logind session on its own console.
      remote=""
      while read -r instance; do
        pid=$(jq -r .pid <<< "$instance")
        session=$(sed -n 's|.*/session-\([^/]*\)\.scope$|\1|p' "/proc/$pid/cgroup" 2> /dev/null)
        [ -n "$session" ] || continue
        [ "$(loginctl show-session "$session" -p VTNr --value)" = ${toString cfg.vt} ] && remote=$instance
      done < <(hyprctl instances -j | jq -c '.[]')
      [ -n "$remote" ] || { echo "No remote Hyprland session is running." >&2; exit 1; }
      pid=$(jq -r .pid <<< "$remote")
      HYPRLAND_INSTANCE_SIGNATURE=$(jq -r .instance <<< "$remote")
      WAYLAND_DISPLAY=$(jq -r .wl_socket <<< "$remote")
      export HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY
      echo "Serving Hyprland $HYPRLAND_INSTANCE_SIGNATURE (pid $pid)."
      "$@" &
      server=$!
      while kill -0 "$pid" 2> /dev/null && kill -0 "$server" 2> /dev/null; do sleep 2; done
      kill "$server" 2> /dev/null || true
      wait "$server" || true
      echo "Hyprland $pid or the server ended; restarting on the current session." >&2
      exit 1
    '';
  };
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
  options.bresilla.system.remote.headless = lib.mkEnableOption "the desktop only as the remote session, started over SSH with `sudo hypr-remote start`";

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
      description = "RDP port; the firewall only admits it on the VPN interfaces.";
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

  (lib.mkIf config.bresilla.system.remote.headless {
    services.greetd.enable = lib.mkForce false;
    # Morf still adds wants to greetd.service; masking it keeps that stub from starting.
    systemd.services.greetd.enable = false;
    systemd.defaultUnit = lib.mkForce "multi-user.target";
    # Morf still gives the greeter a home; without greetd it needs to be a system user.
    users.users.greeter = {
      isSystemUser = true;
      group = "greeter";
    };
    users.groups.greeter = { };
    bresilla.system.remote.rdp = {
      enable = lib.mkDefault true;
      autoStart = lib.mkDefault false;
    };
  })

  # Repeated failed logins get the address banned, except on the overlay and the links.
  (lib.mkIf ssh.enable {
    services.openssh.enable = true;
    services.fail2ban = { enable = lib.mkDefault true; ignoreIP = [ "100.64.0.0/10" "10.99.0.0/24" "10.77.0.0/24" ]; };
  })

  # Gitea's SSH on hive, reached from anywhere through the Cloudflare tunnel.
  {
    programs.ssh.extraConfig = ''
      Host git.bresilla.com
        User gitea
        ProxyCommand ${pkgs.cloudflared}/bin/cloudflared access ssh --hostname ssh-git.bresilla.com
    '';
  }

  (lib.mkIf cfg.enable {
    environment.systemPackages = [ command ];
    # RDP only from the VPNs, never the LAN.
    networking.firewall.interfaces.netbird0.allowedTCPPorts = [ cfg.port ];
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];

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
        # eva's own session, as at the login screen: its config starts eva itself.
        ExecStart = "${config.programs.hyprland.package}/bin/start-hyprland -- --config /etc/xdg/hypr/session.lua";
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
        ExecStart = "${lib.getExe follow} ${hypr-rdp}/bin/hypr-rdp --auth-mode ssh --authorized-keys /etc/ssh/authorized_keys.d/${user} --bind 0.0.0.0:${toString cfg.port} --egfx-codec avc420 --fps 60";
        Restart = "always";
        RestartSec = 3;
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
