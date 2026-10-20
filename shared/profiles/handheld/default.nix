{
  config,
  lib,
  pkgs,
  bresilla,
  ...
}:
{
  options.bresilla.handheld.faceButtons = lib.mkOption {
    type = lib.types.enum [
      "xbox"
      "nintendo"
    ];
    default = "xbox";
    description = "Face button labels; nintendo swaps A/B and X/Y so they act as labelled.";
  };

  config = {
    # A touch handheld with game controls and Morf's touch gestures, but no modem.
    # Everything a handheld has is listed here, nothing is inherited. Device modules
    # set the panel's rotation and scale.
    nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
    services.smartd.enable = false;
    bresilla.features.network.cellular.enable = false;

    programs.eva.enable = true;
    programs.eva.pattern.enable = false;
    programs.eva.usePackagedShell = true;
    programs.eva.phone.enable = true;
    programs.eva.phone.gestureDriver = "native";
    # Morf keys settings by the theme's store path; keep one file across updates.
    systemd.user.services.morf.environment.EVA_SETTINGS = lib.mkDefault "%h/.local/state/morf/eva.json";
    # The settings from before eva was named, carried over once.
    systemd.user.services.morf.preStart = ''
      if [ ! -e "$HOME/.local/state/morf/eva.json" ] && [ -e "$HOME/.local/state/morf/caelestia.json" ]; then
        cp -p "$HOME/.local/state/morf/caelestia.json" "$HOME/.local/state/morf/eva.json"
      fi
    '';
    # Apps started from Morf inherit its PATH; a login's one lets them find setuid sudo.
    systemd.user.services.morf.environment.PATH = lib.mkForce (lib.concatStringsSep ":" [
      "/run/wrappers/bin"
      "/etc/profiles/per-user/${config.bresilla.user.name}/bin"
      "/nix/var/nix/profiles/default/bin"
      "/run/current-system/sw/bin"
      "/run/current-system/sw/sbin"
    ]);

    bresilla.features.desktop.enable = lib.mkDefault true;
    bresilla.features.desktop.audio.enable = lib.mkDefault true;
    bresilla.features.desktop.audio.jack.enable = lib.mkDefault true;
    bresilla.features.desktop.flatpak.enable = lib.mkDefault true;
    bresilla.programs.flatpak.apps = [
      "com.github.tchx84.Flatseal"
      "org.mozilla.firefox"
      "app.zen_browser.zen"
      "org.chromium.Chromium"
      "net.lockbook.Lockbook"
      "com.anydesk.Anydesk"
      "com.rustdesk.RustDesk"
      "com.freerdp.FreeRDP"
      "com.moonlight_stream.Moonlight"
      "org.zotero.Zotero"
    ];
    xdg.mime.defaultApplications = lib.genAttrs [
      "text/html"
      "application/xhtml+xml"
      "x-scheme-handler/http"
      "x-scheme-handler/https"
      "x-scheme-handler/about"
      "x-scheme-handler/unknown"
    ] (_: "app.zen_browser.zen.desktop");

    bresilla.features.network.bluetooth.enable = lib.mkDefault true;
    bresilla.features.network.wifi.enable = lib.mkDefault true;
    bresilla.system.remote.ssh.enable = lib.mkDefault true;
    bresilla.services.netbird.routingFeatures = lib.mkDefault "client";
    bresilla.services.vpnClients.mullvad.enable = lib.mkDefault true;
    bresilla.features.system.uinput.enable = lib.mkDefault true;
    services.accounts-daemon.enable = lib.mkDefault true;
    services.udisks2.enable = lib.mkDefault true;
    services.upower.enable = lib.mkDefault true;
    bresilla.programs.steamArm64.enable = lib.mkDefault true;
    bresilla.programs.steamArm64.session.enable = lib.mkDefault true;
    bresilla.programs.decky.enable = lib.mkDefault true;

    # InputPlumber presents the built-in controls as one standard gamepad for
    # Steam. packages/ builds the release with the AYN Odin 3 profile on Cachix.
    services.inputplumber = {
      enable = true;
      package = (bresilla.inputplumber or pkgs.inputplumber) // {
        meta.mainProgram = "inputplumber";
      };
    };
    # It finds its device profiles through XDG_DATA_DIRS; the module points it at
    # the system profile, which does not link share/inputplumber. setfacl hides
    # the raw devices from games.
    systemd.services.inputplumber.environment.XDG_DATA_DIRS =
      lib.mkForce "${config.services.inputplumber.package}/share";
    systemd.services.inputplumber.path = [ pkgs.acl ];

    # As on Armada: present the controls as a Steam Deck controller, so Steam
    # gets its own buttons, back grips and Steam Input; profiles default to Xbox.
    systemd.services.inputplumber-deck-target = {
      description = "Present the handheld controls as a Steam Deck controller";
      after = [ "inputplumber.service" ];
      bindsTo = [ "inputplumber.service" ];
      wantedBy = [ "inputplumber.service" ];
      path = [ pkgs.systemd ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        device=/org/shadowblip/InputPlumber/CompositeDevice0
        call() {
          busctl --system call org.shadowblip.InputPlumber "$device" \
            org.shadowblip.Input.CompositeDevice "$@"
        }
        for attempt in $(seq 1 30); do
          call SetTargetDevices as 1 deck-uhid && break
          sleep 1
        done
        ${lib.optionalString (config.bresilla.handheld.faceButtons == "nintendo") ''
          # The default mappings plus ABXY by label rather than by position.
          profile=/run/inputplumber-handheld.yaml
          cat ${config.services.inputplumber.package}/share/inputplumber/profiles/default.yaml - > "$profile" <<'EOF'
            - name: Labelled A
              source_event:
                gamepad:
                  button: East
              target_events:
                - gamepad:
                    button: South
            - name: Labelled B
              source_event:
                gamepad:
                  button: South
              target_events:
                - gamepad:
                    button: East
            - name: Labelled X
              source_event:
                gamepad:
                  button: North
              target_events:
                - gamepad:
                    button: West
            - name: Labelled Y
              source_event:
                gamepad:
                  button: West
              target_events:
                - gamepad:
                    button: North
          EOF
          call LoadProfilePath s "$profile"
        ''}
      '';
    };
    # Steam opens the Deck controller's hidraw node directly.
    services.udev.extraRules = ''
      KERNEL=="hidraw*", SUBSYSTEM=="hidraw", KERNELS=="0003:28DE:12F0.*", GROUP="input", MODE="0660"
    '';
  };
}
