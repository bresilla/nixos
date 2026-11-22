# A CI builder for build.bresilla.com on NixOS: what `ci-builder setup` does on
# any other Linux. Emulation for the CI systems this machine lacks and a nix-ssh
# login only the ci container's key may use; hive then reaches it at any address
# it can (LAN, NetBird). For machines it cannot, `tunnel` puts this one on hive's
# cicd0, which it dials and keeps open behind any NAT; its tunnel key lands in
# /var/lib/wireguard/wg-ci.pub for hive's peer list.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.nix.ciBuilder;
  hive = import ./hive.nix;
  emulated = builtins.filter (s: s != pkgs.stdenv.hostPlatform.system) hive.systems;
in
{
  imports = [ ./muros/worker.nix ];

  options.bresilla.nix.ciBuilder = {
    enable = lib.mkEnableOption "building for build.bresilla.com";
    cores = lib.mkOption {
      type = lib.types.ints.between 1 1024;
      default = 8;
      description = "Cores each build of the Muros worker session may use.";
    };
    maxJobs = lib.mkOption {
      type = lib.types.ints.between 1 1024;
      default = 2;
      description = "Builds the Muros worker session runs at once.";
    };
    jobFeatures = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "kvm" "userns" ]);
      default = [ "userns" ];
      description = "Sandbox relaxations Muros CI jobs may request on this machine.";
    };
    tunnel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.77.0.8";
      description = "This machine's address on hive's cicd0, when hive cannot reach it otherwise.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # Above any other setting, mkForce included;
      # the list never holds the machine's own system.
      boot.binfmt.emulatedSystems = lib.mkOverride 49 emulated;
      # Static qemu is cached and links only on x86_64; elsewhere NixOS adds the
      # dynamic one's libraries to the build sandbox itself.
      boot.binfmt.preferStaticEmulators = pkgs.stdenv.hostPlatform.system == "x86_64-linux";

      nix.sshServe = {
        enable = true;
        protocol = "ssh-ng";
        write = true;
        keys = [ hive.ciKey ];
      };
      # Builds arrive with unsigned inputs, which only a trusted user may add.
      nix.settings.trusted-users = [ "nix-ssh" ];

      # The Muros worker session: builds, execution probes and CI jobs as muros-worker.
      services.muros-worker = {
        enable = true;
        acknowledgeTrustedAccess = true;
        authorizedKeys = [ hive.ciKey ];
        emulatedSystems = emulated;
        inherit (cfg) cores maxJobs;
        jobs = { enable = true; features = cfg.jobFeatures; };
      };
    }

    (lib.mkIf (cfg.tunnel != null) {
      networking.wireguard.interfaces.cicd0 = {
        ips = [ "${cfg.tunnel}/32" ];
        mtu = 1412;
        privateKeyFile = "/var/lib/wireguard/wg-ci.key";
        generatePrivateKeyFile = true;
        postSetup = "${pkgs.wireguard-tools}/bin/wg pubkey < /var/lib/wireguard/wg-ci.key > /var/lib/wireguard/wg-ci.pub";
        peers = [{
          name = "hive";
          inherit (hive) publicKey endpoint;
          allowedIPs = [ "${hive.address}/32" ];
          persistentKeepalive = 25;
        }];
      };
      networking.firewall.interfaces.cicd0.allowedTCPPorts = [ 22 ];
    })
  ]);
}
