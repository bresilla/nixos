{ config, lib, ... }:
let
  cfg = config.bresilla.nix;
  # Each device's /etc/nix/builder_ed25519.pub; the private key never leaves it.
  clients = {
    fair = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL1Es6Q2GusfhPn6u6vlQTDcDsrIiagjWMv3mt2FNxtS fair-nix-builder";
    odin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOcsdfySIRLxpBo/VSEGdHIeNT2lPKWl/RzYqeFcbh6s odin-nix-builder";
    lama = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICEbrHGFlodmAgn+kPfKZruHxTVDrdizLaxBZMODFTC/ lama-nix-builder";
  };
  tronHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID4Nhv+W7uVPTu7It9ZGeMdJvMuAl/kwoSV5uXqYUBKD";
in
{
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
        keys = builtins.attrValues clients;
      };
      # Builds arrive with unsigned inputs, which only a trusted user may add.
      nix.settings.trusted-users = [ "nix-ssh" ];
    })

    # The device never compiles x86_64 work itself: without tron the build fails.
    (lib.mkIf cfg.buildOnTron {
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
