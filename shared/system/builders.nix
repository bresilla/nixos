{ config, lib, ... }:
let
  cfg = config.bresilla.nix;
  # Each device's /etc/nix/builder_ed25519.pub, kept as devices/<host>/builder.pub;
  # the private key never leaves the device, which reaches tron over NetBird only.
  devices = ../../devices;
  clients = lib.concatMap (host:
    let pub = devices + "/${host}/builder.pub"; in
    lib.optional (builtins.pathExists pub) ''from="100.64.0.0/10" ${lib.trim (builtins.readFile pub)}'')
    (builtins.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir devices)));
  tronHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID4Nhv+W7uVPTu7It9ZGeMdJvMuAl/kwoSV5uXqYUBKD";
in
{
  imports = [ ../ci-builder/module.nix ];

  options.bresilla.nix = {
    serveBuilds = lib.mkEnableOption "building for the ARM devices, over SSH as nix-ssh";
    buildOnTron = lib.mkEnableOption "sending x86_64 builds (cross-compiled kernels) to tron";
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.serveBuilds {
      nix.sshServe = {
        enable = true;
        protocol = "ssh-ng";
        write = true;
        keys = clients;
      };
      # Builds arrive with unsigned inputs, which only a trusted user may add.
      nix.settings.trusted-users = [ "nix-ssh" ];
    })

    # The device never compiles x86_64 work itself: without tron the build fails.
    (lib.mkIf cfg.buildOnTron {
      warnings = lib.optional (!builtins.pathExists (devices + "/${config.networking.hostName}/builder.pub"))
        "devices/${config.networking.hostName}/builder.pub is missing, so tron refuses this machine's builds.";
      nix.distributedBuilds = true;
      nix.buildMachines = [
        {
          hostName = "tron.netbird";
          sshUser = "nix-ssh";
          sshKey = "/etc/nix/builder_ed25519";
          protocol = "ssh-ng";
          system = "x86_64-linux";
          maxJobs = 4;
          supportedFeatures = [
            "big-parallel"
            "kvm"
            "nixos-test"
            "benchmark"
          ];
        }
      ];
      nix.settings.builders-use-substitutes = true;
      programs.ssh.knownHosts.tron = {
        hostNames = [ "tron.netbird" ];
        publicKey = tronHostKey;
      };
    })
  ];
}
