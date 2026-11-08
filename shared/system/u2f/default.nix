# The YubiKeys as an alternative to the password: an empty answer to the password
# prompt, then a touch (and the key's FIDO2 PIN where asked). The registrations in
# ./keys hold only public data and work on every machine, as they share one origin.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.security.u2f;
  pam = config.security.pam;
  # Just after the password check, so it never holds up a typed password or PIN.
  rule = service: pin: {
    order = pam.services.${service}.rules.auth.unix.order + 50;
    control = "sufficient";
    modulePath = "${pkgs.pam_u2f}/lib/security/pam_u2f.so";
    args = [ "authfile=${./keys}" "origin=pam://bresilla" "appid=pam://bresilla" "cue" ]
      ++ lib.optional pin "pinverification=1";
  };
in
{
  options.bresilla.security.u2f = {
    enable = lib.mkEnableOption "the YubiKeys as an alternative to the password";
    touch = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "eva-lock" "greetd" ];
      description = "PAM services where a touch is enough.";
    };
    touchAndPin = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "sudo" ];
      description = "PAM services that also want the key's FIDO2 PIN.";
    };
  };

  config = lib.mkIf cfg.enable {
    security.pam.services =
      lib.genAttrs cfg.touch (s: { rules.auth.u2f-touch = rule s false; })
      // lib.genAttrs cfg.touchAndPin (s: { rules.auth.u2f-pin = rule s true; });
  };
}
