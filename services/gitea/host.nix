{ config, lib, pkgsUnstable, ... }:
let
  mnt = config.bresilla.server.storage.mount;
  cfg = config.bresilla.server.gitea;
  # Fixed so files on nest keep the same owner across rebuilds.
  uid = 3000;
  # Container UIDs start here on the host: its root is unprivileged, and gitea is
  # 524288 + 3000 = 527288 on hive and on nest's NFS share.
  idBase = config.bresilla.server.idBase;
  address = "10.231.0.2";
  # The mirror's user in the container; its agent group is one above.
  mirrorUid = 3010;
in {
  imports = [ ./mirror/agent.nix ];
  options.bresilla.server.gitea.enable = lib.mkEnableOption "git, git.bresilla.com";
  config = lib.mkIf cfg.enable {
    bresilla.server.containers = [ "gitea" ];
    bresilla.server.keep.gitea = [ "/var/lib/nixos-containers/gitea/var/lib/gitea/custom/conf" "/var/lib/nixos-containers/gitea/var/lib/git-mirror-bot" "/var/lib/nixos-containers/gitea/var/lib/radicle-identity" ];
    bresilla.server.keepTo.gitea = "${mnt}/git/config";

    # The mirror's key lives in hive's TPM; the container only reaches the agent's socket.
    bresilla.services.gitMirrorAgent = { enable = true; gid = idBase + mirrorUid + 1; };

    # Repos, LFS and attachments live on nest; the database stays on hive's mirror.
    bresilla.server.shares."git" = "git";
    # Never start on an empty mount point, or repositories would land on hive.
    systemd.services."container@gitea".unitConfig.RequiresMountsFor = [ "${mnt}/git" ];

    # Public through the Cloudflare tunnel: the web UI, and SSH for clients running cloudflared.
    services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress = {
      "git.bresilla.com" = "http://${address}:80";
      "ssh-git.bresilla.com" = "ssh://${address}:2222";
    };

    # Outbound only (mirrors, webhooks); nothing outside hive can open a connection to it.
    networking.nat = { enable = true; internalInterfaces = [ "ve-gitea" ]; };
    # Radicle peers connect in through the router's 8776 forward; only public repos are served.
    networking.nat.forwardPorts = [ { sourcePort = 8776; destination = "${address}:8776"; proto = "tcp"; } ];
    # Hive sets this link from outside, so the container needs no network control.
    bresilla.server.containerNet.gitea = { host = "10.231.0.1"; local = address; };

    containers.gitea = {
      autoStart = true;
      # Maps the container's own files on the fly instead of rewriting their owners.
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      bindMounts."/srv/gitea" = { hostPath = "${mnt}/git/data"; isReadOnly = false; };
      bindMounts."/run/git-mirror-agent" = { hostPath = "/run/git-mirror-agent"; isReadOnly = true; };
      config = {
        imports = [ ./. ];
        # v28 from unstable: the 26.05 channel stays on 1.27, which gets no more fixes.
        services.gitea.package = pkgsUnstable.gitea;
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
            externalAddress = "ddns.bresilla.net:8776";
            # The old hive node and the throwaway one that held the recovery key.
            hideNodes = [
              "z6MkkNwbjgvcxTX38CxaXh9GwqFGYTQGVQ4n5P2Ce4xxnPEH"
              "z6Mkrp2UV6FAYpqiyXNigr2ViLSG29xk1v7NWZ1DdcVGJgDX"
              # The throwaway key of the 2026-11-14 bridge test.
              "z6MkmXyLV2GJcDE7GJmmGZWRtBEX9bzGsYW78dfUQEt9RkrN"
            ];
            # Nightly beside gitea's; the keys only encrypted to the two YubiKeys.
            backup = {
              directory = "/srv/gitea/backups";
              recipients = config.bresilla.server.recipients;
            };
            bridge.enable = true;
            # build.bresilla.com's results as commit statuses and Radicle job COBs.
            bridge.ci = "https://build.bresilla.com";
          };
          # Public repositories mirrored to GitHub and elsewhere, set per repository.
          # Where each owner mirrors to is set on its settings page, never here.
          mirror = {
            enable = true;
            uid = mirrorUid;
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
  };
}
