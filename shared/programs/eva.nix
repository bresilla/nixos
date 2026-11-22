# eva, the desktop shell, wherever a profile turns it on.
{ config, lib, ... }:
{
  config = lib.mkIf (config.programs.eva.enable or false) {
    # Morf keys settings by the theme's store path; keep one file across updates.
    systemd.user.services.eva.environment.EVA_SETTINGS = lib.mkDefault "%h/.local/state/eva/eva.json";
    # The settings from before eva was named or had its own state folder, carried over
    # once, before eva writes a default.
    systemd.user.services.eva.preStart = lib.mkBefore ''
      for old in "$HOME/.local/state/morf/eva.json" "$HOME/.local/state/morf/caelestia.json"; do
        if [ ! -e "$HOME/.local/state/eva/eva.json" ] && [ -e "$old" ]; then
          mkdir -p "$HOME/.local/state/eva" && cp -p "$old" "$HOME/.local/state/eva/eva.json"
        fi
      done
    '';
    # Apps started from Morf inherit its PATH; a login's one lets them find setuid sudo.
    systemd.user.services.eva.environment.PATH = lib.mkForce (lib.concatStringsSep ":" [
      "/run/wrappers/bin"
      "/etc/profiles/per-user/${config.bresilla.user.name}/bin"
      "/nix/var/nix/profiles/default/bin"
      "/run/current-system/sw/bin"
      "/run/current-system/sw/sbin"
    ]);
  };
}
