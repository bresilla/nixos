# patty: a pattern, drawn on a grid or typed on a keypad, for the login and lock
# screens only. It is tried before the password and never instead of it: the
# password (and anything else in the stack) always still works. sudo, su, ssh
# and polkit never get it.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.security.patty;
  # The login and lock screens this machine has: none, one or both.
  screens = lib.optional (config.programs ? eva && config.programs.eva.enable) "eva-lock"
    ++ lib.optional config.services.greetd.enable "greetd";
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
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "A pattern on every machine; it only works once `sudo patty set` saved one.";
    };
    services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = screens;
      defaultText = "the eva lock screen and greetd, where this machine has them";
      example = [ "eva-lock" "greetd" ];
      description = "PAM services, login and lock screens only, that accept the pattern.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ patty ];
    systemd.tmpfiles.rules = [ "d /var/lib/patty 0755 root root - -" ];
    # Patterns saved before the greeter could read their kind get its file now.
    system.activationScripts.patty-kinds.text = ''
      for f in /var/lib/patty/*; do
        case "$f" in *.fails|*.kind) continue ;; esac
        [ -f "$f" ] && [ ! -e "$f.kind" ] || continue
        ${pkgs.coreutils}/bin/cut -d' ' -f1 "$f" > "$f.kind"
        ${pkgs.coreutils}/bin/chmod 0644 "$f.kind"
      done
    '';
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
