{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.bin;

  release = {
    version = "0.2.4";
    assets = {
      x86_64-linux = {
        name = "bin_linux_amd64.tar.gz";
        hash = "sha256-2aQifb1fI+Ud73TmL/L2rUiRgWNwexg1G/It1b/PbjQ=";
      };
      aarch64-linux = {
        name = "bin_linux_arm64.tar.gz";
        hash = "sha256-Ux4mLp7JW+QzjZJVxvcsCu2QCWo/ooyWFC6wzPmj/EU=";
      };
    };
  };

  asset = release.assets.${pkgs.stdenv.hostPlatform.system} or (throw "bin ${release.version} has no release asset for ${pkgs.stdenv.hostPlatform.system}");

  binBinary = pkgs.stdenvNoCC.mkDerivation {
    pname = "bin";
    version = release.version;

    src = pkgs.fetchurl {
      url = "https://github.com/termworks/bin/releases/download/${release.version}/${asset.name}";
      inherit (asset) hash;
    };

    sourceRoot = ".";

    installPhase = ''
      runHook preInstall
      install -D -m 0755 bin "$out/bin/bin"
      runHook postInstall
    '';

    meta.mainProgram = "bin";
  };

  repoUrl = repo:
    if
      lib.hasPrefix "http://" repo
      || lib.hasPrefix "https://" repo
      || lib.hasPrefix "docker://" repo
      || lib.hasPrefix "goinstall://" repo
    then
      repo
    else
      "https://${repo}";

  repoName = repo:
    lib.removeSuffix ".git" (baseNameOf (lib.removeSuffix "/" repo));

  normalizeEntry = entry:
    let
      name = entry.name or (repoName entry.repo);
      path = entry.path or "${cfg.installDir}/${name}";
      tags = entry.tags or [ (entry.tag or "default") ];
    in
    {
      inherit path;
      manifest = {
        inherit path tags;
        url = repoUrl entry.repo;
        provider = entry.provider or "github";
      } // lib.optionalAttrs (entry ? description) {
        inherit (entry) description;
      };
    };

  normalizedEntries = map normalizeEntry cfg.entries;
  manifest = pkgs.writeText "bin-list.json" (builtins.toJSON {
    default_path = cfg.installDir;
    bins = builtins.listToAttrs (map (entry: {
      name = entry.path;
      value = entry.manifest;
    }) normalizedEntries);
  });

  binWrapper = pkgs.writeShellApplication {
    name = "bin";
    runtimeInputs = [ binBinary ];
    text = ''
      github_token_file=${lib.escapeShellArg config.sops.secrets."github/token".path}
      if [[ -r "$github_token_file" ]]; then
        github_token="$(<"$github_token_file")"
        export GITHUB_TOKEN="$github_token"
        export GITHUB_AUTH_TOKEN="$github_token"
      fi
      set +e
      ${lib.getExe' binBinary "bin"} "$@"
      status="$?"
      set -e
      if [[ "$status" -eq 0 && "''${1:-}" == "ensure" && "$(id -u)" -eq 0 && -d ${lib.escapeShellArg cfg.installDir} ]]; then
        find ${lib.escapeShellArg cfg.installDir} -maxdepth 1 -type f -exec chmod 0755 {} +
      fi
      exit "$status"
    '';
  };
in
{
  options.bresilla.programs.bin = {
    enable = lib.mkEnableOption "system bin binary manager" // {
      default = true;
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = binWrapper;
      description = "bin package exposed system-wide.";
    };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/bin/list.json";
      description = "System bin manifest path.";
    };

    stateFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/bin/config.state.json";
      description = "Mutable system bin state path.";
    };

    installDir = lib.mkOption {
      type = lib.types.str;
      default = "/usr/local/bin";
      description = "Directory where sudo bin installs system binaries.";
    };

    entries = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [
        { repo = "github.com/sigoden/argc"; }
        { repo = "github.com/atuinsh/atuin"; }
        { repo = "github.com/sharkdp/bat"; }
        { repo = "github.com/termworks/bin"; }
        { repo = "github.com/theryangeary/choose"; }
        { repo = "github.com/dandavison/delta"; }
        { repo = "github.com/eza-community/eza"; }
        { repo = "github.com/charmbracelet/gum"; }
        { repo = "github.com/termworks/hexe"; }
        { repo = "github.com/ipinfo/cli"; name = "ipinfo"; }
        { repo = "github.com/jj-vcs/jj"; }
        { repo = "github.com/starship/starship"; }
        { repo = "github.com/austinjones/tab-rs"; name = "tab"; }
        { repo = "github.com/tealdeer-rs/tealdeer"; name = "tldr"; }
        { repo = "github.com/sxyazi/yazi"; }
        { repo = "github.com/ajeetdsouza/zoxide"; }
      ];
      example = [
        {
          repo = "github.com/sharkdp/fd";
          tag = "default";
        }
      ];
      description = "Initial system bin manifest entries.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
      pkgs.patchelf
    ];

    environment.etc."bin/list.json".source = manifest;

    environment.sessionVariables.PATH = [ cfg.installDir ];

    system.activationScripts.binDirs = lib.stringAfter [ "etc" ] ''
      mkdir -p ${lib.escapeShellArg cfg.installDir} /var/lib/bin
      chmod 0755 ${lib.escapeShellArg cfg.installDir} /var/lib/bin
      find ${lib.escapeShellArg cfg.installDir} -maxdepth 1 -type f -exec chmod 0755 {} +
    '';
  };
}
