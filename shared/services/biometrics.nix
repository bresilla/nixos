{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.features.system;
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.fingerprint.enable {
      services.fprintd.enable = true;
    })

    (lib.mkIf config.bresilla.features.desktop.enable {
      # Morf starts its fingerprint reader independently of password entry.
      security.pam.services.morf-lock.fprintAuth = false;
      security.pam.services.greetd.fprintAuth = false;

      security.pam.services.morf-lock-finger = lib.mkIf cfg.fingerprint.enable {
        text = ''
          # Fingerprint reader only; password entry uses morf-lock separately.
          auth sufficient ${config.services.fprintd.package}/lib/security/pam_fprintd.so
          auth required ${pkgs.pam}/lib/security/pam_deny.so
          account include morf-lock
        '';
      };
    })
  ];
}
