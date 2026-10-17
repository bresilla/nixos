{ lib, modulesPath, ... }:

let
  keys = (import ../users/authorized-keys.nix).bresilla;
in
{
  # The minimal installer, reachable over Ethernet with no screen attached.
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  nixpkgs.hostPlatform = "x86_64-linux";
  networking.hostName = "nixos-installer";
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # The stock image keeps SSH stopped and the nixos account passwordless.
  systemd.services.sshd.wantedBy = lib.mkForce [ "multi-user.target" ];
  services.openssh.settings.PasswordAuthentication = lib.mkForce true;
  users.users.nixos = {
    initialHashedPassword = lib.mkForce null;
    password = "nixos";
    openssh.authorizedKeys.keys = keys;
  };
  users.users.root.openssh.authorizedKeys.keys = keys;

  # Answers as nixos-installer.local, so its address need not be looked up.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };
}
