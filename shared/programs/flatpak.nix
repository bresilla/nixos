{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.flatpak;
  # Zen reads its system policies from its systemconfig extension (/app/etc/zen inside),
  # and they replace the ones it ships, so those two are kept here.
  zenPolicies = (pkgs.formats.json { }).generate "zen-policies.json" {
    policies = { DisableAppUpdate = true; DontCheckDefaultBrowser = true; } // cfg.zenPolicies;
  };
  zenExtension = "/var/lib/flatpak/extension/app.zen_browser.zen.systemconfig/${pkgs.stdenv.hostPlatform.parsed.cpu.name}/stable";
in
{
  options.bresilla.programs.flatpak = {
    everyday.enable = lib.mkEnableOption "the everyday apps: browsers, remote desktops, notes and Zotero";
    defaultBrowser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "app.zen_browser.zen";
      description = "Flatpak ID that opens web links and pages.";
    };
    apps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Flatpak application IDs to install. Unlisted Flatpaks are left alone.";
    };
    overrides = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = { "org.blender.Blender" = [ "--filesystem=/srv/assets" "--talk-name=org.freedesktop.Flatpak" ]; };
      description = "`flatpak override --system` arguments per application ID; each listed app's system overrides are exactly these.";
    };
    zenPolicies = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Firefox enterprise policies for the Zen Flatpak (see about:policies).";
    };
  };

  config = lib.mkMerge [
  {
    bresilla.programs.flatpak.apps = lib.mkIf cfg.everyday.enable (lib.mkBefore [
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
    ]);
    # search.bresilla.com as Zen's search engine, from the address bar too.
    bresilla.programs.flatpak.zenPolicies.SearchEngines = lib.mkIf cfg.everyday.enable {
      Add = [{
        Name = "search";
        Description = "search.bresilla.com";
        URLTemplate = "https://search.bresilla.com/search?q={searchTerms}";
        SuggestURLTemplate = "https://search.bresilla.com/ac?q={searchTerms}";
        IconURL = "https://search.bresilla.com/favicon.svg";
        Method = "GET";
        Alias = "@s";
      }];
      Default = "search";
    };
    xdg.mime.defaultApplications = lib.mkIf (cfg.defaultBrowser != null) (lib.genAttrs [
      "text/html"
      "application/xhtml+xml"
      "x-scheme-handler/http"
      "x-scheme-handler/https"
      "x-scheme-handler/about"
      "x-scheme-handler/unknown"
    ] (_: "${cfg.defaultBrowser}.desktop"));
  }
  (lib.mkIf (config.bresilla.features.desktop.flatpak.enable && lib.elem "app.zen_browser.zen" cfg.apps) {
    # A copy, not a link: the sandbox cannot see /nix/store.
    systemd.services.zen-policies = {
      description = "Zen's system policies";
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ zenPolicies ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        ${pkgs.coreutils}/bin/install -D -m 0644 ${zenPolicies} ${zenExtension}/policies/policies.json
      '';
    };
  })
  (lib.mkIf (config.bresilla.features.desktop.flatpak.enable && (cfg.apps != [ ] || cfg.overrides != { })) {
    systemd.services.flatpak-default-apps = {
      description = "Install default Flatpak applications";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "flatpak-system-helper.service"
      ];
      wantedBy = [ "multi-user.target" ];
      path = [
        config.services.flatpak.package
        pkgs.coreutils
        pkgs.getent
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # network-online can come before Wi-Fi does; retry until Flathub answers.
        Restart = "on-failure";
        RestartSec = "30s";
      };
      unitConfig = {
        StartLimitIntervalSec = 600;
        StartLimitBurst = 10;
      };

      script = ''
        # A switch restarts this while DNS can be briefly down; wait up to a minute.
        for _ in $(seq 30); do
          getent hosts flathub.org >/dev/null && break
          sleep 2
        done

        flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

        ${lib.concatMapStringsSep "\n" (app: ''
          if flatpak info --system ${lib.escapeShellArg app} >/dev/null 2>&1; then
            flatpak update --system --noninteractive ${lib.escapeShellArg app}
          else
            flatpak install --system --noninteractive flathub ${lib.escapeShellArg app}
          fi
        '') cfg.apps}

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (app: args: ''
          flatpak override --system --reset ${lib.escapeShellArg app}
          flatpak override --system ${lib.escapeShellArgs args} ${lib.escapeShellArg app}
        '') cfg.overrides)}
      '';
    };
  })
  ];
}
