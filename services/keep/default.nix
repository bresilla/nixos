# Secrets that exist only on this server, kept encrypted to the YubiKeys so a new
# machine can take over: each service lists its own in bresilla.server.keep. Daily and
# at boot, each set changed since last time is packed (tar, then base64 so gopass
# holds it as text), encrypted to the recipients and left readable in /var/lib/server-keep,
# from where to-gopass.sh takes it into gopass. The server never sees the store.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.server;
  out = "/var/lib/server-keep";
  state = "/var/lib/server-keep-state";
  encrypt = lib.concatMapStringsSep " " (r: "-r ${lib.escapeShellArg r}") cfg.recipients;
in {
  options.bresilla.server = {
    keep = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      description = "Name to the absolute paths (files or folders) only this server holds.";
    };
    recipients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "age recipients the kept secrets are encrypted to, as gopass's.";
    };
  };

  config = lib.mkIf (cfg.recipients != [ ]) {
    # The machine's own SSH host keys, so its address keeps its identity.
    bresilla.server.keep.ssh = [ "/etc/ssh/ssh_host_ed25519_key" "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key" "/etc/ssh/ssh_host_rsa_key.pub" ];

    systemd.services.server-keep = {
      description = "Encrypted copies of the secrets only this server holds";
      path = [ pkgs.age pkgs.age-plugin-yubikey pkgs.gnutar pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; UMask = "0077"; };
      script = ''
        install -d -m 0755 ${out}
        install -d -m 0700 ${state}
        keep() {
          name=$1; shift
          have=()
          for p in "$@"; do [ -e "$p" ] && have+=("''${p#/}"); done
          [ ''${#have[@]} -gt 0 ] || { echo "$name: nothing there yet"; return; }
          plain=$(tar -C / --sort=name --mtime=@0 --numeric-owner -cf - "''${have[@]}" | base64 -w0)
          sum=$(printf '%s' "$plain" | sha256sum | cut -d' ' -f1)
          [ "$(cat ${state}/$name 2>/dev/null)" = "$sum" ] && return
          printf '%s\n' "$plain" | age ${encrypt} -o ${out}/$name.age.new
          chmod 0644 ${out}/$name.age.new
          mv ${out}/$name.age.new ${out}/$name.age
          echo "$sum" > ${state}/$name
          echo "$name: new encrypted copy"
        }
        ${lib.concatStrings (lib.mapAttrsToList (name: paths: ''
          keep ${lib.escapeShellArg name} ${lib.escapeShellArgs paths}
        '') cfg.keep)}
      '';
    };
    systemd.timers.server-keep = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "5min"; OnCalendar = "daily"; Persistent = true; };
    };
  };
}
