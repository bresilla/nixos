# nest pushes its btrbk snapshots to the dump targets listed on hive's hub.
# dump.json beside this holds nest's manager key; targets accept it from nest's addresses.
{ lib, ... }:
let
  link = lib.importJSON ../link.json;
in {
  bresilla.dump.manager = {
    enable = true;
    hub = "http://${link.hive}:9103";
    volume = "/mnt/data-store";
    snapshotDir = ".snapshots";
    shares = map (name: "@${name}") (lib.attrNames (lib.filterAttrs (_: s: s.backup) (import ../shares.nix).shares));
    keep = { to = "/mnt/data-store/@vault/config/dump"; recipients = import ../../../shared/users/recipients.nix; };
  };
}
