{ config, lib, pkgs, ... }:

let
  user = config.bresilla.user.name;
  home = config.users.users.${user}.home;
  cfg = config.bresilla.dotfiles;
  settings = if cfg.source != null then cfg.source else
    throw "Choose a dotfiles repository through install.sh, or set bresilla.dotfiles.source in the device configuration.";
  dotfiles = builtins.fetchTree (settings // { type = "git"; shallow = true; });
in
{
  options.bresilla.dotfiles = {
    enable = lib.mkEnableOption "Home Manager dotfile links" // { default = true; };
    source = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
      default = null;
      description = "Selected Git dotfiles source: url, rev and narHash, saved per device.";
    };
  };

  config = {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "before-home-manager";
      users.${user} = {
        imports = lib.optional cfg.enable (dotfiles + "/nix/home.nix");
        home.username = user;
        home.homeDirectory = home;
        home.stateVersion = "26.05";
      };
    };

    system.build.prepareDotfiles = lib.mkIf cfg.enable (pkgs.writeShellScript "prepare-dotfiles" ''
      set -euo pipefail
      target_root="''${1:-}"
      user_home="$target_root"${lib.escapeShellArg home}
      checkout="$user_home/.dot"
      test -d "$user_home" || { echo "User home does not exist: $user_home" >&2; exit 1; }
      export PATH=${lib.makeBinPath [ pkgs.gitMinimal pkgs.coreutils ]}:"$PATH"
      # Fetch/autostash also writes Git metadata when run as root. Restore the
      # owner's access even when a merge stops with a conflict.
      trap 'test ! -d "$checkout" || ${pkgs.coreutils}/bin/chown -R -h --reference="$user_home" "$checkout"' EXIT
      if [[ -e "$checkout" || -L "$checkout" ]]; then
        test -e "$checkout/.git" || { echo "Existing $checkout is not a Git checkout; leaving it untouched" >&2; exit 1; }
        remote=$(${pkgs.gitMinimal}/bin/git -c safe.directory="$checkout" -C "$checkout" remote get-url origin)
        chosen=${lib.escapeShellArg settings.url}
        remote="''${remote%/}"; remote="''${remote%.git}"
        chosen="''${chosen%/}"; chosen="''${chosen%.git}"
        test "$remote" = "$chosen" || { echo "Existing $checkout uses another repository; leaving it untouched" >&2; exit 1; }
        ${pkgs.bash}/bin/bash ${./installer/update-dotfiles.sh} "$checkout" ${lib.escapeShellArg settings.rev}
      else
        GIT_TERMINAL_PROMPT=0 ${pkgs.gitMinimal}/bin/git clone --depth 1 -- ${lib.escapeShellArg settings.url} "$checkout"
        if [[ "$(${pkgs.gitMinimal}/bin/git -C "$checkout" rev-parse HEAD)" != ${lib.escapeShellArg settings.rev} ]]; then
          GIT_TERMINAL_PROMPT=0 ${pkgs.gitMinimal}/bin/git -C "$checkout" fetch --depth 1 origin ${lib.escapeShellArg settings.rev}
          ${pkgs.gitMinimal}/bin/git -C "$checkout" checkout --detach ${lib.escapeShellArg settings.rev}
        fi
        ${pkgs.coreutils}/bin/chown -R -h --reference="$user_home" "$checkout"
      fi
      test -f "$checkout/nix/home.nix" || { echo "Missing $checkout/nix/home.nix" >&2; exit 1; }
      test -d "$checkout/.config" || { echo "Missing $checkout/.config" >&2; exit 1; }
    '');
  };
}
