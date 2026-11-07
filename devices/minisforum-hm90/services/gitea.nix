let
  # Fixed so files on nest keep the same owner across rebuilds.
  uid = 3000;
  # Container UIDs start here on the host: its root is unprivileged, and gitea is
  # 524288 + 3000 = 527288 on hive and on nest's NFS share.
  idBase = 524288;
  address = "10.231.0.2";
in {
  # Repos, LFS and attachments live on nest; the database stays on hive's mirror.
  fileSystems."/mnt/nest/gitea" = {
    device = "nest.link:/data/gitea";
    fsType = "nfs4";
    options = [ "_netdev" "nofail" "noatime" ];
  };

  # Public through the Cloudflare tunnel: the web UI, and SSH for clients running cloudflared.
  services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress = {
    "git.bresilla.com" = "http://${address}:3000";
    "ssh-git.bresilla.com" = "ssh://${address}:2222";
  };

  # Outbound only (mirrors, webhooks); nothing outside hive can open a connection to it.
  networking.nat = { enable = true; internalInterfaces = [ "ve-gitea" ]; externalInterface = "enp4s0"; };
  # Hive configures the link, so the container needs no network control (hardening.nix).
  hive.containerNet.gitea = { host = "10.231.0.1"; local = address; };

  containers.gitea = {
    autoStart = true;
    privateUsers = idBase;
    # Maps the container's own files on the fly instead of rewriting their owners.
    extraFlags = [ "--private-users-ownership=auto" ];
    privateNetwork = true;
    bindMounts."/srv/gitea" = { hostPath = "/mnt/nest/gitea"; isReadOnly = false; };
    config = {
      imports = [ ../../../shared/services/server/gitea ];
      bresilla.services.gitea = { domain = "git.bresilla.com"; appName = "bresilla"; inherit uid; };
    };
  };
}
