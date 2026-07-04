{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.user;
in
{
  options.bresilla.user = {
    name = lib.mkOption {
      type = lib.types.str;
      default = "bresilla";
      description = "Primary normal user account.";
    };

    hashedPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime path to the primary user's hashed password file.";
    };
  };

  config = {
    programs.zsh.enable = true;

    users.groups = {
      flatpak = { };
      libvirtd = { };
      plugdev = { };
      uinput = { };
    };

    users.users.${cfg.name} =
      {
        isNormalUser = true;
        shell = pkgs.zsh;
        extraGroups = [
          "audio"
          "dialout"
          "flatpak"
          "input"
          "kvm"
          "libvirtd"
          "networkmanager"
          "plugdev"
          "render"
          "uinput"
          "video"
          "wheel"
        ];
        openssh.authorizedKeys.keys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDFB4lRnoOLjfKLDOEwab1GWQuE98NXLcWtwmf4ucLqLAezmujqiz4+ZsRr7lVvbVm7yoOCdxkmU6FjwnA8abJ6z1112iULTYLrOMPSVGn/nArLMx5oCQxf6n/bE2K1sEKX7BeDaAyNrVPk0oAvkMYzjqQ6oFqVQMnpvGpSO3IrIyJn1QoKT7hYc4VWxfSzrzjQ9SIttc362sx+i4bNIq08fbTO+Gbwkc1TLCPBOsh0/18YmNR32HKSkTKa2jeizM2ycpv/q/ZEnzI0W+4YMKQf6RGFDRLvs6nqp+CNndmUFWLQ53yAiyEoPlj/+I6+tOVK6p6lryQQ3y4LDwol0fTCuq3x1YmVvfbzqI5zey9MEHQGaMLKdXA26EoKs/T3SGOIIQ6may5UYp4B2m50El0eHCAYO9nJjX/sRRmzh36dp3Ic83Z9EPGH0/6sDHYgc/PtHT4igpXKQedxfAcbsExqEG2oopbsMPbQZT4lXkC2vesHYI+h2D7BNDSmz7harBlYcnyCzFkQ5JZOFFEFlo2LK3b/tEzLr0o3Zh9x6H8/vr6yDxYfm0Wd9fTHZSqIL1hqnhKJUaHMpPjfjfjacyMZ5sgILoHpt5koeMBI68X1pI91nhaLIhjmtBB4ml4vXjM8ncuQN3Gy1hKoCtE5Q/JIfkJbP6fP0X27DJ9w82fX0Q== openpgp:0x0CDAEA9E"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBiuf0IbDIui0Hrw/0x/4d7CLYHUAKFiH82zKb6vzKzG trim.bresilla@outlook.com"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIClW59Mw6Y1S8YH8kGNQBC4EiEGzu2dWDacn4Tp1jt4a void.cypher28@gmail.com"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDMsIfXu9To/i1R5vsgcmZt/3NvFosBUkF4mecr3+dof allonce"
        ];
      }
      // lib.optionalAttrs (cfg.hashedPasswordFile != null) {
        hashedPasswordFile = cfg.hashedPasswordFile;
      };
  };
}
