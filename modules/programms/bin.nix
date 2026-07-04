{ config, lib, pkgs, ... }:

let
  # warpcli/bin 0.2.2
  warpbin = builtins.getFlake "github:warpcli/bin/a55116f25eb2e2fa718a23b7ee569d135b5e52ee";
  cfg = config.bresilla.programs.bin;
  defaultPackage = warpbin.packages.${pkgs.stdenv.hostPlatform.system}.default;
  binPackage = pkgs.writeShellScriptBin "bin" ''
    github_token_file=${lib.escapeShellArg config.sops.secrets."github/token".path}
    if [[ -r "$github_token_file" ]]; then
      github_token="$(<"$github_token_file")"
      export GITHUB_TOKEN="$github_token"
      export GITHUB_AUTH_TOKEN="$github_token"
    fi
    exec ${cfg.package}/bin/src "$@"
  '';
  repoUrl = repo:
    if lib.hasPrefix "http://" repo || lib.hasPrefix "https://" repo || lib.hasPrefix "docker://" repo || lib.hasPrefix "goinstall://" repo then
      repo
    else
      "https://${repo}";
  repoName = repo:
    lib.removeSuffix ".git" (baseNameOf (lib.removeSuffix "/" repo));
  normalizeEntry = entry:
    let
      name = repoName entry.repo;
      tags = [ (entry.tag or "default") ];
      path = "${cfg.installDir}/${name}";
      manifest = {
        inherit path tags;
        url = repoUrl entry.repo;
      };
    in
    {
      inherit path manifest;
    };
  normalizedEntries = map normalizeEntry cfg.entries;
  manifestBins = builtins.listToAttrs (map (entry: {
    name = entry.path;
    value = entry.manifest;
  }) normalizedEntries);
  manifest = pkgs.writeText "bin-list.json" (builtins.toJSON {
    default_path = cfg.installDir;
    bins = manifestBins;
  });
in
{
  options.bresilla.programs.bin = {
    enable = lib.mkEnableOption "warpcli/bin installer-time default binary installation";
    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "warpcli/bin package used by the installer.";
    };
    installDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/bin";
      description = "Directory where bin installs managed binaries.";
    };
    entries = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [
        {
          repo = "github.com/nektos/act";
          tag = "other";
        }

        {
          repo = "github.com/sigoden/aichat";
          tag = "other";
        }

        {
          repo = "github.com/sigoden/argc";
          tag = "default";
        }

        {
          repo = "github.com/asciinema/asciinema";
          tag = "other";
        }

        {
          repo = "github.com/atuinsh/atuin";
          tag = "default";
        }

        {
          repo = "github.com/sharkdp/bat";
          tag = "default";
        }

        {
          repo = "github.com/steveyegge/beads";
          tag = "other";
        }

        {
          repo = "codeberg.org/lukeflo/bibiman";
          tag = "other";
        }

        {
          repo = "github.com/oven-sh/bun";
          tag = "other";
        }

        {
          repo = "github.com/theryangeary/choose";
          tag = "default";
        }

        {
          repo = "github.com/savedra1/clipse";
          tag = "other";
        }

        {
          repo = "github.com/cloudflare/cloudflared";
          tag = "net";
        }

        {
          repo = "github.com/openai/codex";
          tag = "other";
        }

        {
          repo = "github.com/charmbracelet/crush";
          tag = "other";
        }

        {
          repo = "github.com/dandavison/delta";
          tag = "default";
        }

        {
          repo = "github.com/jetify-com/devbox";
          tag = "default";
        }

        {
          repo = "github.com/oug-t/difi";
          tag = "other";
        }

        {
          repo = "github.com/direnv/direnv";
          tag = "default";
        }

        {
          repo = "github.com/sigoden/dufs";
          tag = "other";
        }

        {
          repo = "github.com/chojs23/ec";
          tag = "other";
        }

        {
          repo = "github.com/Gentleman-Programming/engram";
          tag = "other";
        }

        {
          repo = "github.com/eza-community/eza";
          tag = "default";
        }

        {
          repo = "github.com/cli/cli";
          tag = "other";
        }

        {
          repo = "github.com/dlvhdr/gh-dash";
          tag = "other";
        }

        {
          repo = "github.com/orhun/git-cliff";
          tag = "default";
        }

        {
          repo = "github.com/gittower/git-flow-next";
          tag = "default";
        }

        {
          repo = "github.com/git-town/git-town";
          tag = "git";
        }

        {
          repo = "github.com/sinclairtarget/git-who";
          tag = "other";
        }

        {
          repo = "github.com/babarot/gomi";
          tag = "default";
        }

        {
          repo = "github.com/aaif-goose/goose";
          tag = "other";
        }

        {
          repo = "github.com/charmbracelet/gum";
          tag = "default";
        }

        {
          repo = "github.com/home-assistant/cli";
          tag = "other";
        }

        {
          repo = "github.com/TStansel/handoff";
          tag = "other";
        }

        {
          repo = "github.com/termworks/hexe";
          tag = "default";
        }

        {
          repo = "github.com/github/hub";
          tag = "default";
        }

        {
          repo = "github.com/gohugoio/hugo";
          tag = "other";
        }

        {
          repo = "github.com/pythops/impala";
          tag = "other";
        }

        {
          repo = "github.com/ipinfo/cli";
          tag = "default";
        }

        {
          repo = "github.com/jj-vcs/jj";
          tag = "default";
        }

        {
          repo = "github.com/casey/just";
          tag = "default";
        }

        {
          repo = "github.com/lockbook/lockbook";
          tag = "other";
        }

        {
          repo = "github.com/rust-lang/mdBook";
          tag = "default";
        }

        {
          repo = "github.com/mamba-org/micromamba-releases";
          tag = "default";
        }

        {
          repo = "github.com/bresilla/midy";
          tag = "other";
        }

        {
          repo = "github.com/charmbracelet/mods";
          tag = "other";
        }

        {
          repo = "github.com/fnichol/names";
          tag = "other";
        }

        {
          repo = "github.com/netbirdio/netbird";
          tag = "default";
        }

        {
          repo = "github.com/fosrl/newt";
          tag = "net";
        }

        {
          repo = "github.com/guyfedwards/nom";
          tag = "other";
        }

        {
          repo = "github.com/pokanop/nostromo";
          tag = "other";
        }

        {
          repo = "github.com/opencloud-eu/opencloud";
          tag = "other";
        }

        {
          repo = "github.com/ollama/ollama";
          tag = "other";
        }

        {
          repo = "github.com/fosrl/olm";
          tag = "net";
        }

        {
          repo = "github.com/anomalyco/opencode";
          tag = "other";
        }

        {
          repo = "github.com/zjrosen/perles";
          tag = "other";
        }

        {
          repo = "github.com/jacek-kurlit/pik";
          tag = "other";
        }

        {
          repo = "github.com/prefix-dev/pixi";
          tag = "default";
        }

        {
          repo = "github.com/mfontanini/presenterm";
          tag = "other";
        }

        {
          repo = "github.com/lotabout/rargs";
          tag = "other";
        }

        {
          repo = "github.com/rerun-io/rerun";
          tag = "other";
        }

        {
          repo = "github.com/bee-san/RustScan";
          tag = "other";
        }

        {
          repo = "github.com/matheus-git/systemd-manager-tui";
          tag = "other";
        }

        {
          repo = "github.com/sentrux/sentrux";
          tag = "other";
        }

        {
          repo = "github.com/servicer-labs/servicer";
          tag = "other";
        }

        {
          repo = "github.com/yassinebridi/serpl";
          tag = "other";
        }

        {
          repo = "github.com/sourcegraph/sg";
          tag = "other";
        }

        {
          repo = "github.com/runkids/skillshare";
          tag = "other";
        }

        {
          repo = "github.com/charmbracelet/soft-serve";
          tag = "other";
        }

        {
          repo = "github.com/Spotifyd/spotifyd";
          tag = "other";
        }

        {
          repo = "github.com/sheepla/srss";
          tag = "other";
        }

        {
          repo = "github.com/starship/starship";
          tag = "default";
        }

        {
          repo = "github.com/smallstep/cli";
          tag = "other";
        }

        {
          repo = "github.com/zircote/subcog";
          tag = "other";
        }

        {
          repo = "github.com/matheus-git/systemd-manager-tui";
          tag = "other";
        }

        {
          repo = "github.com/austinjones/tab-rs";
          tag = "default";
        }

        {
          repo = "github.com/tealdeer-rs/tealdeer";
          tag = "default";
        }

        {
          repo = "github.com/tree-sitter/tree-sitter";
          tag = "other";
        }

        {
          repo = "github.com/trunk-rs/trunk";
          tag = "other";
        }

        {
          repo = "github.com/scipenai/tylax";
          tag = "other";
        }

        {
          repo = "github.com/hyperb1iss/unifly";
          tag = "other";
        }

        {
          repo = "github.com/rustwasm/wasm-pack";
          tag = "other";
        }

        {
          repo = "github.com/sxyazi/yazi";
          tag = "default";
        }

        {
          repo = "github.com/eclipse-zenoh/zenoh";
          tag = "default";
        }

        {
          repo = "github.com/ajeetdsouza/zoxide";
          tag = "default";
        }
      ];
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      binPackage
      pkgs.patchelf
    ];

    programs.nix-ld = {
      enable = true;
      libraries = with pkgs; [
        stdenv.cc.cc
        zlib
        zstd
        openssl
        curl
        libxml2
        libffi
        ncurses
        readline
        sqlite
        xz
        bzip2
        expat
        glib
      ];
    };

    environment.etc."bin/list.json".source = manifest;
    environment.variables = {
      BIN_CONFIG_FILE = "/var/lib/bin/list.json";
      BIN_STATE_FILE = "/var/lib/bin/config.state.json";
      BIN_DEFAULT_PATH = cfg.installDir;
    };
    environment.shellInit = ''
      case ":$PATH:" in
        *:${cfg.installDir}:*) ;;
        *) export PATH="${cfg.installDir}:$PATH" ;;
      esac
    '';
    system.activationScripts.binManifest = lib.stringAfter [ "etc" ] ''
      mkdir -p ${lib.escapeShellArg cfg.installDir} /var/lib/bin
      install -D -m 0644 ${manifest} /var/lib/bin/list.json
    '';
  };
}
