# Trust in bresilla's own certificate authority (cert.bresilla.com), which signs
# the services reached only inside, such as vault.bresilla.com. Its root key lives
# on the YubiKeys; only its certificate is here. The system store covers most
# programs; browsers keep their own databases, so each login adds it there too.
{ lib, pkgs, ... }:
let
  root = ./pki/bresilla-root.crt;
  name = "bresilla Root CA";
in
{
config = lib.mkIf (builtins.pathExists root) {
  security.pki.certificateFiles = [ root ];

  # Chromium (Nix and Flatpak), Firefox and Zen: every certificate database found.
  systemd.user.services.trust-bresilla-root = {
    description = "Trust bresilla's root CA in browser certificate databases";
    wantedBy = [ "default.target" ];
    serviceConfig = { Type = "oneshot"; };
    path = [ pkgs.nssTools pkgs.coreutils pkgs.findutils ];
    script = ''
      dbs=("$HOME/.pki/nssdb")
      [ -d "$HOME/.var/app/org.chromium.Chromium" ] && dbs+=("$HOME/.var/app/org.chromium.Chromium/.pki/nssdb")
      while IFS= read -r db; do dbs+=("$(dirname "$db")"); done < <(
        find "$HOME/.mozilla" "$HOME/.zen" "$HOME/.var/app/org.mozilla.firefox" \
          "$HOME/.var/app/app.zen_browser.zen" -name cert9.db 2>/dev/null)
      for db in "''${dbs[@]}"; do
        mkdir -p "$db"
        [ -e "$db/cert9.db" ] || certutil -N -d "sql:$db" --empty-password
        certutil -D -d "sql:$db" -n ${lib.escapeShellArg name} 2>/dev/null || true
        certutil -A -d "sql:$db" -n ${lib.escapeShellArg name} -t "C,," -i ${root}
      done
    '';
  };
};
}
