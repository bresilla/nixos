{ config, lib, pkgs, ... }:
let
  address = "10.231.2.2";
  # atticd's own command line, switched to atticadm, as the cache UI mints tokens.
  atticadm = builtins.replaceStrings [ "/bin/atticd " "--mode ${config.containers.cache.config.services.atticd.mode}" ]
    [ "/bin/atticadm " "" ] config.containers.cache.config.systemd.services.atticd.serviceConfig.ExecStart;
  # The secrets nixbot and the builders page read; asked for once, kept only here.
  ciSecrets = pkgs.writeShellApplication {
    name = "ci-secrets";
    runtimeInputs = [ pkgs.coreutils pkgs.nixos-container ];
    text = ''
      d=/var/lib/nixos-containers/ci/var/lib/ci/secrets
      install -d -m 0700 "$d"
      ask() {
        local value
        read -rsp "$2: " value
        echo
        [ -n "$value" ] && printf '%s' "$value" > "$d/$1"
        return 0
      }
      echo "Leave a question empty to keep what is saved."
      ask gitea-token "gitea token of the nixbot user"
      ask gitea-oauth-secret "client secret of gitea's nixbot OAuth app"
      # CI's push token for the bresilla cache, minted in the cache container.
      if [ ! -s "$d/attic-token" ]; then
        nixos-container run cache -- systemd-run --quiet --wait --pipe --collect \
          -p EnvironmentFile=/var/lib/atticd.env ${atticadm} make-token --sub ci --validity 5y \
          --pull bresilla --push bresilla > "$d/attic-token"
        echo "attic push token: made"
      fi
      [ -s "$d/builders-token" ] || head -c 24 /dev/urandom | base64 | tr -d '/+=' > "$d/builders-token"
      chmod 0600 "$d"/*
      echo "builders page token: $(< "$d/builders-token")"
      nixos-container run ci -- systemctl restart nixbot.service ci-builders.service
    '';
  };
in {
  # Public through the Cloudflare tunnel; gitea's webhooks arrive the same way.
  services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress."build.bresilla.com" = "http://${address}:80";

  networking.nat = { enable = true; internalInterfaces = [ "ve-ci" ]; externalInterface = "enp4s0"; };
  # Hive sets this link from outside, so the container needs no network control.
  hive.containerNet.ci = { host = "10.231.2.1"; local = address; };
  environment.systemPackages = [ ciSecrets ];

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
        gitea = "https://git.bresilla.com";
        oauthId = "REPLACE_WITH_CLIENT_ID";
        admins = [ "bresilla" ];
        cache = "http://10.231.1.2:8080";
        systems = [ "x86_64-linux" "aarch64-linux" "riscv64-linux" ];
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
