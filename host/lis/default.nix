# The LIS applier module: reads generated/system.lis.json (the only artifact
# the installer emits) and derives everything this flake previously took from
# generated host.nix / user.nix / disko.nix. A repo without a document gets an
# empty module.
{ config, lib, modulesPath, pkgs, ... }:

let
  docFile = ../generated/system.lis.json;
  hasDoc = builtins.pathExists docFile;
  doc = builtins.fromJSON (builtins.readFile docFile);

  x = doc."x-nixos" or { };
  system = doc.system or { };
  users = doc.users or [ ];
  primary = lib.head users;
  extras = lib.drop 1 users;
  hasPassword = user: (user.password or { }) ? hash;
  passwordFile = name: "/var/lib/nixos-install/passwd-${name}.hash";
  sshEnabled = ((doc.network or { }).ssh or { }).enabled or false;
in
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  config = lib.mkIf hasDoc (lib.mkMerge [
    {
      networking.hostName = lib.mkDefault (system.hostname or "nixos");
      time.timeZone = lib.mkDefault (system.timezone or "UTC");

      bresilla.features.system.architecture = lib.mkDefault "unknown";
      bresilla.features.system.cpuVendor = lib.mkDefault "unknown";

      boot.loader.systemd-boot.enable = lib.mkDefault true;
      boot.loader.efi = {
        canTouchEfiVariables = lib.mkDefault true;
        efiSysMountPoint = lib.mkDefault "/boot/efi";
      };

      disko.devices = lib.mkForce (import ./to-disko.nix { inherit lib doc; });
    }

    # The installer's secrets decision (x-nixos.secrets = false → sops off).
    (lib.mkIf (!(x.secrets or true)) {
      bresilla.secrets.enable = false;
    })

    # Accounts: the primary user drives bresilla.user; extras are plain users.
    (lib.mkIf (users != [ ]) (lib.mkMerge [
      {
        bresilla.user.name = lib.mkDefault primary.name;
        bresilla.features.system.ssh.enable = lib.mkDefault sshEnabled;
        users.users.${primary.name}.extraGroups = lib.mkForce (primary.groups or [ ]);
      }
      (lib.mkIf (hasPassword primary) {
        bresilla.user.hashedPasswordFile = lib.mkDefault (passwordFile primary.name);
      })
      {
        users.users = lib.listToAttrs (map
          (user: lib.nameValuePair user.name ({
            isNormalUser = true;
            shell = pkgs.zsh;
            extraGroups = user.groups or [ ];
          } // lib.optionalAttrs (hasPassword user) {
            hashedPasswordFile = passwordFile user.name;
          }))
          extras);
      }
    ]))
  ]);
}
