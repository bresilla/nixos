{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.features.system;
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.fingerprint.enable {
      services.fprintd.enable = true;
    })

    (lib.mkIf cfg.face.enable {
      services.gaze = {
        enable = true;
        gui.enable = false;
        # Camera choice and enrollment remain local to each machine.
        mutableConfig = true;
        pam.defaultServices = [ "sudo" "polkit-1" ];
      };
    })

    (lib.mkIf config.bresilla.features.desktop.enable {
      # Morf starts independent readers alongside its password conversation.
      # Keep camera/fingerprint waits out of that password conversation.
      security.pam.services.morf-lock.fprintAuth = false;
      security.pam.services.greetd.fprintAuth = false;

      security.pam.services.morf-lock-face = lib.mkIf cfg.face.enable {
        text = ''
          # Face reader only; a failed match must not prompt for a password.
          auth sufficient ${config.services.gaze.package}/lib/security/pam_gaze.so
          auth required ${pkgs.pam}/lib/security/pam_deny.so
          account include morf-lock
        '';
      };

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
