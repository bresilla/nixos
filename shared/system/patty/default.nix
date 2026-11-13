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
  keyring = pkgs.writers.writePython3Bin "patty-keyring" {
    libraries = [ pkgs.python3Packages.dbus-python ];
  } (builtins.readFile ./keyring.py);
  patty = pkgs.writeShellApplication {
    name = "patty";
    runtimeInputs = [ pkgs.mkpasswd pkgs.acl pkgs.coreutils pkgs.util-linux pkgs.openssl pkgs.libargon2 pkgs.getent pkgs.gnused pkgs.findutils keyring ];
    text = builtins.readFile ./patty.sh;
  };
  # Just before the password check, as an alternative to it.
  rule = service: {
    order = config.security.pam.services.${service}.rules.auth.unix.order - 50;
    control = "sufficient";
    modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
    args = [ "quiet" "expose_authtok" "${patty}/bin/patty" "check" ];
  };
  # After the keyring daemon starts: opens the keyrings with the login's pattern.
  unlock = service: {
    order = (config.security.pam.services.${service}.rules.session.gnome_keyring.order or 12600) + 10;
    control = "optional";
    modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
    args = [ "quiet" "${patty}/bin/patty" "unlock" ];
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
        case "$f" in *.fails|*.kind|*.seal|*.key|*.pat|*.pw) continue ;; esac
        [ -f "$f" ] && [ ! -e "$f.kind" ] || continue
        ${pkgs.coreutils}/bin/cut -d' ' -f1 "$f" > "$f.kind"
        ${pkgs.coreutils}/bin/chmod 0644 "$f.kind"
      done
      # The lock screen checks as the user and reads the pattern's locked key.
      for f in /var/lib/patty/*.pat; do
        [ -f "$f" ] || continue
        u=$(${pkgs.coreutils}/bin/basename "$f" .pat)
        ${pkgs.acl}/bin/setfacl -m "u:$u:r" "$f" || true
      done
    '';
    security.pam.services = lib.genAttrs cfg.services (s: {
      rules.auth.patty = rule s;
      rules.session.patty = unlock s;
    }) // {
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
