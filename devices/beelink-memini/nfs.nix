{
  # NFSv4 only, served to hive over the direct link.
  services.nfs.server = {
    enable = true;
    exports = ''
      /data/gitea  10.99.0.1(rw,sync,no_subtree_check,no_root_squash)
    '';
  };
  services.nfs.settings.nfsd.vers3 = false;
  networking.firewall.interfaces.enp1s0.allowedTCPPorts = [ 2049 ];
}
