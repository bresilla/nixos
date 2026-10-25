{ config, lib, pkgs, bresilla, ... }:

let
  cfg = config.bresilla.programs.steamArm64;
  steamosManager = bresilla."steamos-manager" or null;
  # Valve's ARM64 client channel and runtime, as Armada OS pins them.
  channel = "steamdeck_publicbeta";
  manifest = "steam_client_${channel}_linuxarm64";
  runtime = pkgs.fetchurl {
    url = "https://repo.steampowered.com/steamrt3c/images/3c.0.20260729.253765/steam-runtime-steamrt-arm64.tar.xz";
    sha256 = "d0e21db9538bcbdfa51b46f0acbba8a3dcbd6e5f345ae410a6b89d9b90b7d09e";
  };

  # Windows games: Wine ARM64EC with FEX, with Armada's DXVK feature probe.
  protonName = "proton-cachyos-11.0-arm64";
  proton = pkgs.stdenvNoCC.mkDerivation {
    pname = "proton-cachyos-arm64";
    version = "11.0-20261005-slr";
    src = pkgs.fetchurl {
      url = "https://github.com/CachyOS/proton-cachyos/releases/download/cachyos-11.0-20261005-slr/proton-cachyos-11.0-20261005-slr-arm64.tar.xz";
      hash = "sha256-5ZtkbnPeSvIf8vbHlbKOe2yIkhSzxtr45lpWY0zQbDc=";
    };
    nativeBuildInputs = [ pkgs.perl ];
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      tool=$out/share/steam/compatibilitytools.d/${protonName}
      mkdir -p "$tool"
      cp -r . "$tool"
      substituteInPlace "$tool/proton" \
        --replace-fail "MODERN_DXVK_FEATURES = ['descriptorIndexing']" \
          "MODERN_DXVK_FEATURES = ['descriptorIndexing', 'storageBuffer8BitAccess']"
      perl -0pi \
        -e 's/("display_name"\s+)"[^"]+"/$1"Proton 11.0 CachyOS (ARM64)"/;' \
        -e 's/("compat_tools"\s*\{\s*)"[^"]+"/$1"${protonName}"/' \
        "$tool/compatibilitytool.vdf"
    '';
  };

  # Seeds ~/.local/share/Steam on first start, as Armada's bootstrap does;
  # afterwards Steam updates itself.
  launch = pkgs.writeShellScript "steam-arm64-launch" ''
    set -euo pipefail
    root="''${STEAM_ROOT:-$HOME/.local/share/Steam}"
    arm="$root/steamrtarm64/steam"
    if [[ ! -x $arm ]]; then
      cdn=https://client-update.steamstatic.com
      mkdir -p "$root/package" "$HOME/.steam"
      echo ${channel} > "$root/package/beta"
      for link in steam root; do ln -sfn ../.local/share/Steam "$HOME/.steam/$link"; done
      ln -sfn ../.local/share/Steam/linux32 "$HOME/.steam/sdk32"
      ln -sfn ../.local/share/Steam/linux64 "$HOME/.steam/sdk64"
      ln -sfn ../.local/share/Steam/linuxarm64 "$HOME/.steam/sdkarm64"
      curl -fsSL -o "$root/package/${manifest}.manifest" "$cdn/${manifest}"
      seed=$(grep -oE 'bins_linuxarm64_linuxarm64\.zip\.[0-9a-f]+' "$root/package/${manifest}.manifest" | head -1)
      curl -fsSL -o "$root/package/$seed" "$cdn/$seed"
      unzip -q -o "$root/package/$seed" -d "$root"
      # The archive drops executable bits.
      while IFS= read -r name; do
        file -b "$root/$name" | grep -qE 'interpreter /lib/ld-linux|shell script|Python script' &&
          chmod +x "$root/$name"
      done < <(unzip -Z1 "$root/package/$seed" | grep -v '/$')
      tar -xJf ${runtime} -C "$root"
      ibus=$(find "$root/steam-runtime-steamrt-arm64" -path '*/files/lib/aarch64-linux-gnu/libibus-1.0.so.5.*' -type f | sort | tail -n1)
      mkdir -p "$root/lib/aarch64-linux-gnu"
      ln -sfn "../../''${ibus#"$root/"}" "$root/lib/aarch64-linux-gnu/libibus-1.0.so.5"
    fi

    ${lib.optionalString (cfg.session.uiScale != null) ''
      # Replace Steam's auto display scale; a scale chosen in Steam is kept.
      vdf="$root/config/config.vdf"
      auto=$(sed -n 's/.*"AutoScaleFactor"[[:space:]]*"\([0-9.]*\)".*/\1/p' "$vdf" 2>/dev/null | head -1 || true)
      if [[ -n $auto ]] && grep -q "\"ScaleFactor\"[[:space:]]*\"$auto\"" "$vdf"; then
        sed -i "s/\(\"ScaleFactor\"[[:space:]]*\"\)$auto\"/\1${cfg.session.uiScale}\"/" "$vdf"
      fi
    ''}
    export LD_LIBRARY_PATH="$root/steamrtarm64:$root/lib/aarch64-linux-gnu''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export PATH="$root/steam-runtime-steamrt-arm64/bin:$PATH"
    # Steam restores these for compatibility tools, which otherwise get no PATH.
    export SYSTEM_PATH=$PATH SYSTEM_LD_LIBRARY_PATH=$LD_LIBRARY_PATH
    # Decky Loader reaches Steam's UI through CEF remote debugging.
    touch "$root/.cef-enable-remote-debugging"
    # Deck mode only for a plain desktop start: Steam drops forwarded commands
    # such as -ifrunning steam://shortpowerpress that carry -steamdeck.
    args=()
    [[ -n ''${GAMESCOPE_WAYLAND_DISPLAY:-} || $# -gt 0 ]] || args=(-steamdeck)
    cd "$root/steamrtarm64"
    exec "$arm" "''${args[@]}" "$@"
  '';

  # Steam's "Switch to Desktop" and the desktop's "Return to Gaming Mode" both
  # record the next mode and end the current one; gaming-session loops on it.
  sessionState = ''state="''${XDG_STATE_HOME:-$HOME/.local/state}/steamos-session"'';
  sessionSelect = pkgs.writeShellScriptBin "steamos-session-select" ''
    ${sessionState}
    mkdir -p "$(dirname "$state")"
    case "''${1:-}" in
      gamescope)
        echo gamescope > "$state"
        hyprctl dispatch 'hl.dsp.exit()' >/dev/null 2>&1 || hyprctl dispatch exit
        ;;
      *)
        echo desktop > "$state"
        steam -shutdown
        ;;
    esac
  '';
  # Armada's powerbuttond: while gaming mode owns the power key, a short press
  # is Steam's sleep and a long one its power menu.
  powerButton = pkgs.writeShellApplication {
    name = "steam-powerbuttond";
    runtimeInputs = with pkgs; [ coreutils evtest ];
    text = ''
      long_ms=1000
      device=
      for _ in $(seq 1 15); do
        for event in /dev/input/event*; do
          case "$(cat "/sys/class/input/$(basename "$event")/device/name" 2>/dev/null)" in
            *pwrkey*|*[Pp]ower\ [Bb]utton*) device=$event; break 2 ;;
          esac
        done
        sleep 1
      done
      [[ -n $device ]] || { echo "steam-powerbuttond: no power key" >&2; exit 1; }
      press() { steam -ifrunning "steam://$1" > /dev/null 2>&1 || true; }

      exec 3< <(evtest "$device" 2> /dev/null)
      state=idle pressed=0
      while true; do
        status=0
        if [[ $state == held ]]; then
          left=$((long_ms - ($(date +%s%3N) - pressed)))
          if (( left <= 0 )); then
            press longpowerpress
            state=draining
            continue
          fi
          IFS= read -r -u 3 -t "$(printf '%d.%03d' $((left / 1000)) $((left % 1000)))" line || status=$?
          (( status > 128 )) && continue
        else
          IFS= read -r -u 3 line || status=$?
        fi
        (( status == 0 )) || exit 1
        case "$state:$line" in
          held:*"(KEY_POWER), value 0"*) press shortpowerpress; state=idle ;;
          draining:*"(KEY_POWER), value 0"*) state=idle ;;
          idle:*"(KEY_POWER), value 1"*) pressed=$(date +%s%3N); state=held ;;
        esac
      done
    '';
  };

  gamingClient = pkgs.writeShellScript "steam-gaming-client" ''
    export XDG_CURRENT_DESKTOP=${if cfg.session.backend == "hyprland" then "Hyprland" else "gamescope"}
    export XDG_SESSION_DESKTOP=steam
    export XDG_SESSION_TYPE=wayland
    # Portals are activated by the user manager, outside this login's process
    # tree. Give them this session's live display rather than the previous desktop's.
    ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd \
      DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE \
      ${lib.optionalString (cfg.session.backend == "hyprland") "HYPRLAND_INSTANCE_SIGNATURE"}
    exec ${lib.getExe steam} -gamepadui \
      ${if cfg.session.backend == "hyprland" then "-fullscreen" else "-steamos3 -steampal -steamdeck"}
  '';
  hyprlandGaming = pkgs.writeShellScript "steam-gaming-hyprland-session" ''
    ${gamingClient}
    status=$?
    hyprctl dispatch 'hl.dsp.exit()' >/dev/null 2>&1 || hyprctl dispatch exit
    exit "$status"
  '';
  gamingHyprland = pkgs.writeText "steam-gaming-hyprland.lua" ''
    hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
    hl.config({
      general = { border_size = 0, gaps_in = 0, gaps_out = 0 },
      animations = { enabled = false },
      misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        disable_watchdog_warning = true,
        disable_xdg_env_checks = true,
        background_color = "rgb(000000)",
      },
      ecosystem = { no_update_news = true, no_donation_nag = true },
    })
    ${cfg.session.hyprlandExtraConfig}
    hl.on("hyprland.start", function()
      hl.exec_cmd("${hyprlandGaming}")
    end)
  '';
  gamingMode = pkgs.writeShellScript "steam-gaming-mode" ''
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    unset DISPLAY WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE
    # Steam handles the power key while gaming mode owns the display.
    ${pkgs.systemd}/bin/systemd-inhibit --what=handle-power-key:handle-suspend-key \
      --who=steam-powerbuttond --why="Steam handles power in gaming mode" --mode=block \
      ${lib.getExe powerButton} &
    power=$!
    trap 'kill "$power" 2>/dev/null || true; wait "$power" 2>/dev/null || true' EXIT
    ${if cfg.session.backend == "hyprland" then ''
      ${pkgs.systemd}/bin/systemd-cat --identifier=steam-gaming-mode -- \
        ${lib.getExe config.programs.hyprland.package} --config ${gamingHyprland}
    '' else ''
      ${pkgs.systemd}/bin/systemd-cat --identifier=steam-gaming-mode -- \
        ${lib.getExe config.programs.gamescope.package} --steam -f --xwayland-count 2 \
      ${lib.escapeShellArgs cfg.session.gamescopeArgs} \
        -- ${gamingClient}
    ''}
  '';
  gamingDesktop = pkgs.runCommand "steam-gaming-session" {
    passthru.providedSessions = [ "steam" ];
  } ''
    mkdir -p "$out/share/wayland-sessions"
    cat > "$out/share/wayland-sessions/steam.desktop" <<EOF
    [Desktop Entry]
    Name=Steam Gaming Mode
    Comment=${if cfg.session.backend == "hyprland" then "Fullscreen Steam" else "Fullscreen Steam with Gamescope"}
    Exec=${gamingMode}
    Type=Application
    DesktopNames=${if cfg.session.backend == "hyprland" then "Hyprland" else "gamescope"}
    EOF
  '';

  gamingSession = pkgs.writeShellScript "gaming-session" ''
    ${sessionState}
    mkdir -p "$(dirname "$state")"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    sessions=${config.services.displayManager.sessionData.desktops}/share/wayland-sessions
    quick=0
    while (( quick < 3 )); do
      mode=$(cat "$state" 2>/dev/null || echo gamescope)
      # A crash or a logout from either mode comes back to gaming mode.
      echo gamescope > "$state"
      start=$SECONDS
      if [[ $mode == desktop ]]; then
        desktop=$(sed -n 's/^Exec=//p' "$sessions/$(cat /etc/greetd/default-session).desktop" | head -1)
        sh -c "$desktop" || true
      else
        ${gamingMode} || true
      fi
      # Repeated instant exits fall back to the greeter instead of spinning.
      if (( SECONDS - start < 10 )); then quick=$((quick + 1)); else quick=0; fi
    done
  '';
  returnToGaming = pkgs.makeDesktopItem {
    name = "return-to-gaming-mode";
    desktopName = "Return to Gaming Mode";
    exec = "steamos-session-select gamescope";
    icon = "steam";
    categories = [ "Game" ];
  };

  # Steam's -steamdeck mode calls SteamOS hooks; NixOS owns updates, so they
  # report one channel and no update (exit 7).
  steamosHooks = pkgs.runCommand "steamos-hooks" { } ''
    mkdir -p $out/bin/steamos-polkit-helpers
    ln -s ${sessionSelect}/bin/steamos-session-select $out/bin/steamos-session-select
    cat > $out/bin/steamos-select-branch <<'EOF'
    #!/bin/sh
    case "''${1:-}" in -l|-c) echo rel ;; esac
    EOF
    cat > $out/bin/steamos-update <<'EOF'
    #!/bin/sh
    # Steam first probes for duplicate detection, which must succeed.
    for arg in "$@"; do [ "$arg" = --supports-duplicate-detection ] && exit 0; done
    exit 7
    EOF
    chmod +x $out/bin/steamos-select-branch $out/bin/steamos-update
    # Gaming mode calls these through the polkit helper directory; firmware,
    # devkit and branch changes have nothing to do on NixOS.
    helpers=$out/bin/steamos-polkit-helpers
    ln -s ../steamos-update ../steamos-select-branch $helpers/
    for name in jupiter-biosupdate steamos-devkit-mode; do
      printf '#!/bin/sh\nexit 0\n' > $helpers/$name
      chmod +x $helpers/$name
    done
    # As with steamos-update, 7 means no update; 0 would offer a dock update.
    printf '#!/bin/sh\nexit 7\n' > $helpers/jupiter-dock-updater
    chmod +x $helpers/jupiter-dock-updater
  '';

  # The documented SteamRT host assumptions plus what the CEF client loads.
  steam = pkgs.buildFHSEnv {
    name = "steam";
    targetPkgs = pkgs: with pkgs; [
      bash
      coreutils
      curl
      file
      findutils
      gnugrep
      gnutar
      lsb-release
      # Steam finds its own IPC peers with lsof.
      lsof
      steamosHooks
      pciutils
      python3
      unzip
      usbutils
      xdg-utils
      xz
      zenity
      proton
      (runCommand "xorg-locale" { } ''
        mkdir -p $out
        ln -s ${libx11}/share $out/share
      '')
      glibc
      libxcrypt
      libGL
      libdrm
      libgbm
      udev
      libudev0-shim
      libva
      vulkan-loader
      networkmanager
      libcap
      alsa-lib
      libpulseaudio
      pipewire
      at-spi2-atk
      cairo
      cups
      dbus
      expat
      fontconfig
      freetype
      glib
      gtk3
      libxkbcommon
      nspr
      nss
      pango
      wayland
      zlib
      libx11
      libxcomposite
      libxcursor
      libxdamage
      libxext
      libxfixes
      libxi
      libxrandr
      libxrender
      libxscrnsaver
      libxtst
      libxcb
      libxshmfence
      # NEEDED by the ARM64 client's binaries beyond the SteamRT list.
      atk
      brotli
      bzip2
      ffmpeg_7
      gdk-pixbuf
      gtk2
      libasyncns
      libice
      libsm
      libsndfile
      libvdpau
      libxinerama
      openal
      SDL2
      stdenv.cc.cc.lib
      systemd
    ];
    profile = ''
      unset GIO_EXTRA_MODULES
      export SDL_JOYSTICK_DISABLE_UDEV=1
      export LIBGL_DRIVERS_PATH=/run/opengl-driver/lib/dri
      export __EGL_VENDOR_LIBRARY_DIRS=/run/opengl-driver/share/glvnd/egl_vendor.d
      export LIBVA_DRIVERS_PATH=/run/opengl-driver/lib/dri
    '';
    # Steam expects a real /sbin/ldconfig; a symlink loops in nested containers.
    extraBuildCommands = ''
      cp -f $out/usr/{bin,sbin}/ldconfig
    '';
    runScript = launch;
  };
in
{
  options.bresilla.programs.steamArm64 = {
    enable = lib.mkEnableOption "Valve's ARM64 Steam client with Proton CachyOS, as on Armada OS";
    session = {
      enable = lib.mkEnableOption "a selectable fullscreen Steam gaming session";
      autoLogin = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically log into gaming mode and allow switching directly to the desktop.";
      };
      backend = lib.mkOption {
        type = lib.types.enum [ "drm" "hyprland" ];
        default = "drm";
        description = "Use Gamescope's direct DRM output, or fullscreen Steam in a minimal Hyprland compositor.";
      };
      hyprlandExtraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Device display settings for the minimal gaming compositor.";
      };
      gamescopeArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Device-specific gamescope arguments, such as the panel orientation.";
      };
      uiScale = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "1.5";
        description = "Steam's display scale while it still uses its own automatic value.";
      };
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isAarch64) (lib.mkMerge [
    {
      environment.systemPackages = [ steam ];
      hardware.graphics.enable = true;
      hardware.steam-hardware.enable = true;
    }
    (lib.mkIf cfg.session.enable {
      programs.gamescope.enable = lib.mkIf (cfg.session.backend == "drm") true;
      programs.hyprland.enable = lib.mkIf (cfg.session.backend == "hyprland") true;
      xdg.portal.config.gamescope.default = [ "gtk" ];
      services.displayManager.sessionPackages = [ gamingDesktop ];
      environment.systemPackages = [ sessionSelect ] ++ lib.optional cfg.session.autoLogin returnToGaming;
    })
    (lib.mkIf (cfg.session.enable && cfg.session.autoLogin) {
      # Boot logs straight in to the loop; leaving it shows the greeter.
      services.greetd.settings.initial_session = {
        user = config.bresilla.user.name;
        command = "${gamingSession}";
      };
    })
    # Steam enables its power menu and system settings only when SteamOS's
    # manager answers; packages/ builds Armada's version on Cachix.
    (lib.mkIf (cfg.session.enable && cfg.session.backend == "drm" && steamosManager != null) {
      environment.systemPackages = [ steamosManager ];
      systemd.packages = [ steamosManager ];
      services.dbus.packages = [ steamosManager ];
      systemd.services.steamos-manager = {
        overrideStrategy = "asDropin";
        after = [ "inputplumber.service" ];
        wantedBy = [ "multi-user.target" ];
      };
    })
  ]);
}
