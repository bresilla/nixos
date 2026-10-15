{ config, lib, pkgs, bresilla, termworks, ... }:

let
  cfg = config.bresilla.programs.remoteDesktop;
  user = config.bresilla.user.name;
  # Pinned in the bresilla cache; null until the updater has fetched the pin.
  hypr-rdp = bresilla.hypr-rdp or null;
  tty = "tty${toString cfg.vt}";
  home = config.users.users.${user}.home;
  passwordFile = "${home}/.local/share/hypr-rdp/password";
  oslo = termworks.oslo.packages.${pkgs.stdenv.hostPlatform.system}.default;
  # Started by hand over SSH; never at boot. The logic is hypr-remote.lua, run by oslo.
  command = pkgs.writeShellScriptBin "hypr-remote" ''
    export HYPR_REMOTE_USER=${lib.escapeShellArg user} HYPR_REMOTE_VT=${toString cfg.vt}
    export HYPR_REMOTE_PORT=${toString cfg.port} HYPR_REMOTE_PASSWORD_FILE=${lib.escapeShellArg passwordFile}
    export HYPR_REMOTE_CHVT=${pkgs.kbd}/bin/chvt
    exec ${oslo}/bin/oslo --norc ${./hypr-remote.lua} "$@"
  '';
in
{
  options.bresilla.programs.remoteDesktop = {
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
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ command ] ++ lib.optional (hypr-rdp != null) hypr-rdp;

    # A real logind session on its own console, so Hyprland gets the GPU.
    systemd.services.hypr-remote = {
      description = "On-demand Hyprland session for remote desktop";
      after = [ "systemd-user-sessions.service" "getty@${tty}.service" ];
      conflicts = [ "getty@${tty}.service" ];
      environment = {
        XDG_SESSION_TYPE = "wayland";
        XDG_SESSION_CLASS = "user";
        XDG_SEAT = "seat0";
        XDG_VTNR = toString cfg.vt;
        # Lets the hypr-rdp user service tell this session from a local login.
        HYPR_REMOTE = "1";
      };
      serviceConfig = {
        User = user;
        PAMName = "login";
        TTYPath = "/dev/${tty}";
        TTYReset = true;
        TTYVHangup = true;
        TTYVTDisallocate = true;
        StandardInput = "tty-fail";
        UtmpIdentifier = tty;
        UtmpMode = "user";
        ExecStart = "${pkgs.uwsm}/bin/uwsm start -e -D Hyprland hyprland.desktop";
      };
    };

    # hypr-rdp runs only inside the remote session, with the password set on first
    # start; without that file it would accept anyone, so it then stays off.
    systemd.user.services.hypr-rdp = lib.mkIf (hypr-rdp != null) {
      description = "RDP server for the remote Hyprland session";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      unitConfig = {
        ConditionEnvironment = "HYPR_REMOTE=1";
        ConditionPathExists = passwordFile;
      };
      serviceConfig = {
        ExecStart = "${hypr-rdp}/bin/hypr-rdp --username ${user} --password-file ${passwordFile} --bind 0.0.0.0:${toString cfg.port}";
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
  };
}
