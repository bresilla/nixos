{
  config,
  lib,
  pkgs,
  termworks,
  ...
}:

let
  cfg = config.bresilla.user;
  osloShell = termworks.oslo.packages.${pkgs.stdenv.hostPlatform.system}.oslo // {
    shellPath = "/bin/oslo";
  };
in
{
  imports = [ ./home.nix ];

  options.bresilla.user = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Primary normal user account.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = (import ./authorized-keys.nix).${cfg.name} or [ ];
      defaultText = lib.literalExpression "keys for the account name in ./authorized-keys.nix";
      description = "SSH public keys allowed to log in as the primary user.";
    };

    hashedPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime path to the primary user's hashed password file.";
    };
  };

  config = {
    environment.shells = [ osloShell ];

    users.groups = {
      corner = { };
      flatpak = { };
      plugdev = { };
      uinput = { };
    };

    users.users.${cfg.name} = {
      isNormalUser = true;
      shell = osloShell;
      extraGroups = [
        "audio"
        "corner"
        "dialout"
        "flatpak"
        "input"
        "networkmanager"
        "plugdev"
        "render"
        "uinput"
        "video"
        "wheel"
      ]
      ++ lib.optionals config.bresilla.features.system.virtualisation.enable [
        "kvm"
        "libvirtd"
      ];
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    }
    // lib.optionalAttrs (cfg.hashedPasswordFile != null) {
      hashedPasswordFile = cfg.hashedPasswordFile;
    };
  };
}
