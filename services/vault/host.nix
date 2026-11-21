# vault.bresilla.com: Vaultwarden, never on the internet. It has no public DNS record
# and no tunnel route; machines reach it by the name shared/system/hosts.nix gives
# it, on hive's overlay address (overlay.nix), the only place it is reached.
# Its certificate comes from bresilla's own CA (ca.nix), once that exists.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.server.vault;
  domain = "vault.bresilla.com";
  hostAddress = "10.231.5.1";
  address = "10.231.5.2";
  pki = ../../shared/system/pki;
  caReady = builtins.pathExists (pki + "/bresilla-root.crt");
in {
  options.bresilla.server.vault.enable = lib.mkEnableOption "the password vault, vault.bresilla.com";
  config = lib.mkIf cfg.enable {
    bresilla.server.containers = [ "vault" ];
    bresilla.server.keep.vault = [ "/var/lib/nixos-containers/vault/var/lib/vaultwarden/rsa_key.pem" ];
    # Only the overlay reaches it, through the overlay's shared port (overlay.nix).
    bresilla.server.overlay.sites.${domain} = "${address}:443";

    # Outbound only (id.bresilla.com's sign-in); nothing outside hive opens a connection to it.
    networking.nat = { enable = true; internalInterfaces = [ "ve-vault" ]; externalInterface = "enp4s0"; };
    # Hive sets this link from outside, so the container needs no network control.
    bresilla.server.containerNet.vault = { host = hostAddress; local = address; };

    # The nightly database copy (made inside) goes to nest beside id's, kept 30 days.
    # Nest never decides whether the vault works; only that night's copy is missed.
    systemd.services.vault-backup = {
      description = "Copy vault.bresilla.com's backups to nest";
      unitConfig.RequiresMountsFor = [ "/mnt/nest/id" ];
      serviceConfig = { Type = "oneshot"; Nice = 10; };
      path = [ pkgs.coreutils pkgs.findutils ];
      script = ''
        src=/var/lib/nixos-containers/vault/var/backup/vaultwarden
        dst=/mnt/nest/id/vault/$(date -u +%F)
        [ -d "$src" ] || exit 0
        install -d -m 0700 "$dst"
        cp -r --preserve=timestamps "$src"/. "$dst"/
        find /mnt/nest/id/vault -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
      '';
    };
    systemd.timers.vault-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "04:10 UTC"; Persistent = true; };
    };

    containers.vault = {
      autoStart = true;
      privateUsers = 524288;
      # Maps the container's own files on the fly instead of rewriting their owners.
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      config = {
        imports = [ ./. ];
        bresilla.services.vault = {
          inherit domain;
          # Sign in with id.bresilla.com; hive puts the secret here.
          login = {
            authority = "https://id.bresilla.com/oauth2/openid/vault";
            client = "vault";
            envFile = "/var/lib/oidc/vault.env";
          };
          ca = lib.mkIf caReady {
            name = "cert.bresilla.com";
            address = "10.231.6.2";
            directory = "https://cert.bresilla.com:8443/acme/acme/directory";
            root = pki + "/bresilla-root.crt";
          };
        };
      };
    };
  };
}
