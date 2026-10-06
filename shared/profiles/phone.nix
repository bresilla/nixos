{ lib, pkgs, ... }:

let
  pointerConfig = ''
    hl.config({ cursor = { invisible = true } })
  '';
in {
  imports = [ ./graphical.nix ../services/phone-screen.nix ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  # Phone-specific choices stay here; graphical software is shared with laptops.
  services.smartd.enable = false;
  bresilla.services.hyprland.extraConfig = pointerConfig;
  bresilla.services.morf.greeter.extraConfig = pointerConfig;

  # Keep phone preferences writable and stable when the theme path changes.
  # Seed the visible bar once; Caelestia can save other preferences normally.
  systemd.user.services.morf = {
    environment.CAELESTIA_SETTINGS = "%h/.local/state/caelestia/phone.json";
    preStart = ''
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$CAELESTIA_SETTINGS")"
      if [ ! -e "$CAELESTIA_SETTINGS" ]; then
        ${pkgs.coreutils}/bin/install -m 600 ${pkgs.writeText "caelestia-phone.json" (builtins.toJSON {
          edgebar.enabled = "on";
        })} "$CAELESTIA_SETTINGS"
      fi
    '';
  };
}
