{ config, lib, pkgs, paneworks, ... }:

let
  morf = config.bresilla.programs.morf.package;
  user = config.bresilla.user.name;
  userHome = config.users.users.${user}.home;
  greeterFonts = with pkgs; [ roboto material-symbols ibm-plex nerd-fonts."m+" ];
  fontFiles = [
    "${pkgs.roboto}/share/fonts/truetype/Roboto-Regular.ttf"
    "${pkgs.material-symbols}/share/fonts/truetype/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf"
    "${pkgs.ibm-plex}/share/fonts/opentype/IBMPlexMono-Regular.otf"
    "${pkgs.nerd-fonts."m+"}/share/fonts/truetype/NerdFonts/M+/M+1NerdFont-Regular.ttf"
  ];
  caelestiaConfig = pkgs.runCommand "morf-caelestia" { } ''
    mkdir -p "$out"
    cp -R ${paneworks.morf}/examples/shells/caelestia/. "$out/"
    chmod -R u+w "$out"
    mkdir -p "$out/fonts"
    for part in shell lock greet; do
      if [ -d "$out/$part/fonts" ]; then
        cp -R "$out/$part/fonts/." "$out/fonts/"
        rm -rf "$out/$part/fonts"
      fi
      cat > "$out/$part/appearance-default.json" <<'EOF'
    { "theme": "tsugumori", "font": "" }
    EOF
      ln -s ../fonts "$out/$part/fonts"
    done
    ${lib.concatMapStringsSep "\n" (font: ''
      test -f ${lib.escapeShellArg font}
      ln -s ${lib.escapeShellArg font} "$out/fonts/"
    '') fontFiles}
  '';
  # Keep advanced CLI invocations unchanged; protect the default entry points.
  morfDefault = pkgs.writeShellScriptBin "morf" ''
    set -u
    if [ "$#" -gt 1 ]; then exec ${morf}/bin/morf "$@"; fi
    role="''${1:-shell}"
    case "$role" in shell|lock|greet) ;; *) exec ${morf}/bin/morf "$@" ;; esac
    if [ "$role" = shell ] && [ -n "''${MORF_CONFIG:-}" ]; then
      exec ${morf}/bin/morf "$@"
    fi
    root="''${XDG_CONFIG_HOME:-$HOME/.config}"
    if [ "$role" = greet ] && [ -n "''${MORF_GREETER_CONFIG_HOME:-}" ]; then
      root="$MORF_GREETER_CONFIG_HOME"
    fi
    candidate="$root/morf/default/$role/init.lua"
    if [ "$role" = shell ] && [ -r "$root/morf/shell.lua" ]; then candidate="$root/morf/shell.lua"; fi
    fallback="/etc/xdg/morf/default/$role/init.lua"
    if [ -r "$candidate" ]; then
      if [ "$role" = greet ] && [ -n "''${MORF_GREETER_CONFIG_HOME:-}" ]; then
        theme=$(${pkgs.coreutils}/bin/dirname "$(${pkgs.coreutils}/bin/dirname "$(${pkgs.coreutils}/bin/readlink -f "$candidate")")")
        if [ -r "$theme/appearance.json" ]; then export CAELESTIA_APPEARANCE="$theme/appearance.json"; fi
      fi
      check_args=()
      if [ "$role" = lock ]; then check_args=(-- window preview); fi
      if CAELESTIA_DRY_RUN=1 ${pkgs.coreutils}/bin/timeout 10 \
        ${morf}/bin/morf check "$candidate" --no-dbus --isolate --after 0 "''${check_args[@]}" >/dev/null; then
        ${morf}/bin/morf "$candidate"
        status=$?
        if [ "$status" -eq 0 ]; then exit 0; fi
        echo "Morf $role exited with $status; using $fallback" >&2
      else
        echo "Morf $role configuration failed validation; using $fallback" >&2
      fi
    fi
    if [ "$role" = greet ] && [ -n "''${MORF_GREETER_CONFIG_HOME:-}" ]; then unset CAELESTIA_APPEARANCE; fi
    export XDG_CONFIG_DIRS=/etc/xdg
    exec ${morf}/bin/morf "$fallback"
  '';
  greeterAccess = pkgs.writeShellScript "morf-greeter-access" ''
    # No write access, and no directory listing outside the Morf tree.
    home=$(${pkgs.coreutils}/bin/readlink -e ${lib.escapeShellArg userHome}) || exit 0
    root=$(${pkgs.coreutils}/bin/readlink -e "$home/.config/morf") || exit 0
    [ -d "$root" ] || exit 0
    for start in "$home" "$(${pkgs.coreutils}/bin/readlink -e "$home/.config")" "$root"; do
      parent="$start"
      while [ -n "$parent" ]; do
        case "$parent" in "$home"|"$home"/*) ;; *) break ;; esac
        ${pkgs.acl}/bin/setfacl -m u:greeter:--x "$parent" || echo "Cannot grant greeter traversal on $parent" >&2
        parent=$(${pkgs.coreutils}/bin/dirname "$parent")
      done
    done
    case "$root" in
      "$home"/*)
        ${pkgs.acl}/bin/setfacl -R -P -m u:greeter:rX "$root" || echo "Cannot grant greeter read access on $root" >&2
        ${pkgs.findutils}/bin/find "$root" -type d -exec ${pkgs.acl}/bin/setfacl -m d:u:greeter:r-x {} + \
          || echo "Cannot set inherited greeter read access on $root" >&2
        ;;
    esac
    exit 0
  '';
  greeter = pkgs.writeShellScript "morf-greeter" ''
    export PATH=${lib.makeBinPath [ pkgs.systemd pkgs.fontconfig ]}:/run/current-system/sw/bin
    export XDG_CONFIG_HOME=/var/lib/greetd/.config
    export MORF_GREETER_CONFIG_HOME=${lib.escapeShellArg "${userHome}/.config"}
    export XDG_CONFIG_DIRS=${lib.escapeShellArg "${userHome}/.config:/etc/xdg"}
    export XDG_DATA_DIRS=${config.services.displayManager.sessionData.desktops}/share:/run/current-system/sw/share
    exec ${config.system.build.morfGreeterCompositor}
  '';
in {
  imports = [ ./morf-greeter.nix ./hyprland-quiet.nix ./morf-modem.nix ];

  config = lib.mkIf config.bresilla.features.desktop.enable {
    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${greeter}";
        user = "greeter";
      };
    };

    users.users.greeter = {
      home = "/var/lib/greetd";
      createHome = true;
    };

    environment.systemPackages = [ (lib.hiPrio morfDefault) ];
    system.build.morfLauncher = morfDefault;
    system.build.morfGreeter = greeter;
    system.build.morfGreeterAccess = greeterAccess;
    # Account activation reapplies the private home mode, which clears the ACL
    # mask. Regrant traversal even when the Home Manager package did not change.
    system.activationScripts.morfGreeterAccess = {
      deps = [ "users" ];
      text = "${greeterAccess}";
    };
    systemd.services.morf-greeter-access = {
      description = "Allow the greeter to read the primary user's Morf theme";
      wantedBy = [ "multi-user.target" ];
      after = [ "home-manager-${user}.service" ];
      before = [ "greetd.service" ];
      restartTriggers = [ config.home-manager.users.${user}.home.activationPackage ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = greeterAccess;
      };
    };
    systemd.services.greetd.wants = [ "morf-greeter-access.service" ];

    home-manager.users.${user} = { lib, ... }: {
      home.activation.restartMorf = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
        if ${pkgs.systemd}/bin/systemctl --user is-active --quiet morf.service 2>/dev/null; then
          run ${pkgs.systemd}/bin/systemctl --user restart morf.service
        fi
      '';
    };

    environment.etc."xdg/morf/caelestia".source = caelestiaConfig;
    environment.etc."xdg/morf/default".source = caelestiaConfig;
    environment.etc."greetd/default-session" = lib.mkIf config.programs.hyprland.enable {
      text = if config.programs.hyprland.withUWSM then "hyprland-uwsm\n" else "hyprland\n";
    };
    programs.hyprland.withUWSM = lib.mkIf config.programs.hyprland.enable (lib.mkDefault true);

    systemd.user.services.morf = {
      description = "Morf desktop shell";
      wantedBy = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      path = [ "/run/current-system/sw" ];
      serviceConfig = {
        ExecStart = "${morfDefault}/bin/morf shell";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
    security.pam.services.morf-lock = { };
    fonts.packages = greeterFonts;
  };
}
