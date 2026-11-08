let
  address = "10.231.3.2";
in {
  # Public through the Cloudflare tunnel: the one login for git, cache and build.
  services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress."id.bresilla.com" = "http://${address}:80";

  networking.nat = { enable = true; internalInterfaces = [ "ve-id" ]; externalInterface = "enp4s0"; };
  # Hive sets this link from outside, so the container needs no network control.
  hive.containerNet.id = { host = "10.231.3.1"; local = address; };

  containers.id = {
    autoStart = true;
    privateUsers = 524288;
    # Maps the container's own files on the fly instead of rewriting their owners.
    extraFlags = [ "--private-users-ownership=auto" ];
    privateNetwork = true;
    config = {
      imports = [ ../../../shared/services/server/id ];
      bresilla.services.id = {
        domain = "id.bresilla.com";
        admin = { name = "bresilla"; displayName = "Trim Bresilla"; mail = "kushtrimbresilla@gmail.com"; };
      };
    };
  };
}
