{ pkgs, ... }:
let
  address = "10.231.2.2";
in {
  # Public through the Cloudflare tunnel.
  # Its repositories, builders and secrets are set on build.bresilla.com.
  services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress."build.bresilla.com" = "http://${address}:80";

  networking.nat = { enable = true; internalInterfaces = [ "ve-ci" ]; externalInterface = "enp4s0"; };
  # Hive sets this link from outside, so the container needs no network control.
  hive.containerNet.ci = { host = "10.231.2.1"; local = address; };

  containers.ci = {
    autoStart = true;
    privateUsers = 524288;
    # Maps the container's own files on the fly instead of rewriting their owners.
    extraFlags = [ "--private-users-ownership=auto" ];
    privateNetwork = true;
    config = {
      imports = [ ../../../shared/services/server/ci ];
      bresilla.services.ci = {
        domain = "build.bresilla.com";
        # Sign in with id.bresilla.com; hive puts the login secrets here.
        login = {
          issuer = "https://id.bresilla.com/oauth2/openid/build";
          client = "build";
          envFile = "/var/lib/oidc/proxy.env";
          adminClaim = "build_role";
        };
        cache = "http://10.231.1.2:8080";
        inherit ((import ../../../shared/ci-builder/hive.nix)) systems;
        seed = {
          machines = {
            tron = {
              address = "10.77.0.8"; user = "nix-ssh"; jobs = 4; speed = 1; enabled = true;
              features = "big-parallel,kvm,nixos-test,benchmark";
              hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID4Nhv+W7uVPTu7It9ZGeMdJvMuAl/kwoSV5uXqYUBKD";
            };
            lama = {
              address = "10.77.0.9"; user = "nix-ssh"; jobs = 4; speed = 1; enabled = true;
              features = "big-parallel,kvm,nixos-test,benchmark";
              hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGgmI4oQ23K+d0q97UROsVwjpFivsOR3EkswMASIGR1t";
            };
          };
          systems = { x86_64-linux = "tron"; aarch64-linux = "lama"; riscv64-linux = "tron"; };
        };
      };
    };
  };
}
