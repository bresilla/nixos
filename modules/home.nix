{ config, dotfiles, lib, pkgs, ... }:

let
  user = config.bresilla.user.name;
  home = config.users.users.${user}.home;
in
{
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "before-home-manager";
    users.${user} = {
      imports = [ (dotfiles + "/nix/home.nix") ];
      home.username = user;
      home.homeDirectory = home;
      home.stateVersion = "26.05";
    };
  };

  system.build.prepareDotfiles = pkgs.writeShellScript "prepare-dotfiles" ''
    set -euo pipefail
    target_root="''${1:-}"
    user_home="$target_root"${lib.escapeShellArg home}
    checkout="$user_home/.dot"
    test -d "$user_home" || { echo "User home does not exist: $user_home" >&2; exit 1; }
    if [[ -e "$checkout" || -L "$checkout" ]]; then
      test -e "$checkout/.git" || { echo "Existing $checkout is not a Git checkout; leaving it untouched" >&2; exit 1; }
      echo "Using existing $checkout; keeping local edits."
    else
      ${pkgs.gitMinimal}/bin/git clone --depth 1 https://github.com/bresilla/dot.git "$checkout"
      ${pkgs.coreutils}/bin/chown -R --reference="$user_home" "$checkout"
    fi
    for app in kitty nvim oslo; do
      test -d "$checkout/.config/$app" || { echo "Missing $checkout/.config/$app" >&2; exit 1; }
    done
  '';
}
