# patty: a pattern, drawn on a grid or typed on a keypad, for the login and lock
# screens only. It is tried before the password and never instead of it: the
# password (and anything else in the stack) always still works. sudo, su, ssh
# and polkit never get it.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.security.patty;
  patty = pkgs.writeShellApplication {
    name = "patty";
    runtimeInputs = [ pkgs.mkpasswd pkgs.acl pkgs.coreutils ];
    text = builtins.readFile ./patty.sh;
  };
  # Just before the password check, as an alternative to it.
  rule = service: {
    order = config.security.pam.services.${service}.rules.auth.unix.order - 50;
    control = "sufficient";
    modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
    args = [ "quiet" "expose_authtok" "${patty}/bin/patty" "check" ];
  };
in
{
  options.bresilla.security.patty = {
    enable = lib.mkEnableOption "a pattern for the login and lock screens";
    services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "eva-lock" "greetd" ];
      description = "PAM services, login and lock screens only, that accept the pattern.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ patty ];
    systemd.tmpfiles.rules = [ "d /var/lib/patty 0755 root root - -" ];
    security.pam.services = lib.genAttrs cfg.services (s: { rules.auth.patty = rule s; }) // {
      # Only for trying patty out with pamtester: the pattern or nothing.
      patty-test = {
        unixAuth = false;
        rules.auth = {
          patty = rule "patty-test" // { order = 10000; };
          deny = { order = 20000; control = "required"; modulePath = "${config.security.pam.package}/lib/security/pam_deny.so"; };
        };
      };
    };
  };
}
