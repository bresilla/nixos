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
    "git.bresilla.com" = "http://${address}:80";
    "ssh-git.bresilla.com" = "ssh://${address}:2222";
  };

  # Outbound only (mirrors, webhooks); nothing outside hive can open a connection to it.
  networking.nat = { enable = true; internalInterfaces = [ "ve-gitea" ]; externalInterface = "enp4s0"; };
  # Hive sets this link from outside, so the container needs no network control.
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
      # Nothing outside can reach the node, so it keeps its own connections to the
      # main seeds open: they only fetch over a connection while it is up.
      services.radicle.settings.node.connect = [
        "z6MkrLMMsiPWUcNPHcRajuMi9mDfYckSoJyPwwnknocNYPm7@iris.radicle.network:8776"
        "z6Mkmqogy2qEM2ummccUthFEaaHvyYmYBYh3dbe9W4ebScxo@rosa.radicle.network:8776"
      ];
      bresilla.services.gitea = {
        domain = "git.bresilla.com"; appName = "bresilla"; inherit uid; proxy = "10.231.0.1";
        # Every public repository is published on Radicle as well.
        radicle = {
          enable = true;
          # The node is bresilla: his key signs his repositories and his organisations'.
          alias = "bresilla";
          user = "bresilla";
          # The key gitea held for him, which already signs every published repository.
          identityFrom = "/var/lib/radicle-keys/1/radicle";
          # Nightly beside gitea's; the keys only encrypted to his two YubiKeys.
          backup = {
            directory = "/srv/gitea/backups";
            recipients = [
              "age1yubikey1q03sjfgkj7l25va4uhh87gtm5dj3a5f27497ghyrpdzzqe8uagjf5ehtkjf"
              "age1yubikey1qdj8xer5fmxh6nxnenpfkw20l0ekmr9nzhfe2xpcsrdctv7u63pj2r62rzc"
            ];
          };
          bridge.enable = true;
          # build.bresilla.com's results as commit statuses and Radicle job COBs.
          bridge.ci = "https://build.bresilla.com";
        };
        # Sign in with id.bresilla.com; hive puts the secret here.
        login = {
          name = "id";
          discovery = "https://id.bresilla.com/oauth2/openid/gitea/.well-known/openid-configuration";
          client = "gitea";
          secretFile = "/var/lib/oidc/gitea";
          adminClaim = "git_role";
        };
      };
    };
  };
}
