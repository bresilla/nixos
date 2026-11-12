# Staging for gitea with Radicle at rad.bresilla.com: the same gitea module as
# git.bresilla.com, with its own repositories and a node kept off the public network.
# Once proven, git.bresilla.com enables radicle and this container goes.
let
  uid = 3000;
  idBase = 524288;
  address = "10.231.4.2";
in {
  services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress."rad.bresilla.com" = "http://${address}:80";

  networking.nat.internalInterfaces = [ "ve-gitrad" ];
  hive.containerNet.gitrad = { host = "10.231.4.1"; local = address; };

  containers.gitrad = {
    autoStart = true;
    privateUsers = idBase;
    extraFlags = [ "--private-users-ownership=auto" ];
    privateNetwork = true;
    config = {
      imports = [ ../../../shared/services/server/gitea ];
      # Repositories stay on the container's own disk.
      systemd.tmpfiles.rules = [ "d /srv/gitea 0750 gitea gitea -" ];
      bresilla.services.gitea = {
        domain = "rad.bresilla.com"; appName = "bresilla"; inherit uid; proxy = "10.231.4.1";
        radicle = { enable = true; alias = "bresilla-staging"; network = "test"; };
      };
    };
  };
}
