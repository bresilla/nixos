{ lib, ... }:
let
  inherit (import ../shares.nix) shares;
  link = lib.importJSON ../link.json;
in {
  # NFSv4 only, every share served to hive over the direct link.
  services.nfs.server = {
    enable = true;
    exports = lib.concatMapStrings (name: "/data/${name} ${link.hive}(rw,sync,no_subtree_check,no_root_squash)\n")
      (lib.attrNames shares);
  };
  services.nfs.settings.nfsd.vers3 = false;
  networking.firewall.interfaces.enp1s0.allowedTCPPorts = [ 2049 ];
}
