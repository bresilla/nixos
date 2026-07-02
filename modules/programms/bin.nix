let
  # warpcli/bin 0.2.1
  warpbin = builtins.getFlake "github:warpcli/bin/465d78e750b16ab72a8b482f8c70b3b859fe1180";
in
{
  imports = [
    warpbin.nixosModules.default
  ];

  programs.bin = {
    enable = true;
    installDir = "/var/lib/bin/bin";
    configFile = "/var/lib/bin/list.json";
    stateFile = "/var/lib/bin/config.state.json";
    addToPath = true;
    binaries = { };
    entries =     [
      {
        repo = "github.com/nektos/act";
        name = "act";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/sigoden/aichat";
        name = "aichat";
        provider = "github";
        tags = [ "other" ];
        description = "All-in-one LLM CLI tool featuring Shell Assistant, Chat-REPL, RAG, AI Tools & Agents, with access to OpenAI, Claude, Gemini, Ollama, Groq, and more.";
      }
    
      {
        repo = "github.com/sigoden/argc";
        name = "argc";
        provider = "github";
        tags = [ "default" ];
        description = "A Bash CLI framework, also a Bash command runner.";
      }
    
      {
        repo = "github.com/asciinema/asciinema";
        name = "asciinema";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/atuinsh/atuin";
        name = "atuin";
        provider = "github";
        tags = [ "default" ];
      }
    
      {
        repo = "github.com/sharkdp/bat";
        name = "bat";
        provider = "github";
        tags = [ "default" ];
        description = "A cat(1) clone with wings.";
      }
    
      {
        repo = "github.com/steveyegge/beads";
        name = "bd";
        provider = "github";
        tags = [ "other" ];
        description = "Beads - A memory upgrade for your coding agent";
      }
    
      {
        repo = "codeberg.org/lukeflo/bibiman";
        name = "bibiman";
        provider = "codeberg";
        tags = [ "other" ];
        description = "A TUI for fast and simple interacting with your BibLaTeX database";
      }
    
      {
        repo = "github.com/oven-sh/bun";
        name = "bun";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/theryangeary/choose";
        name = "choose";
        provider = "github";
        tags = [ "default" ];
        description = "A human-friendly and fast alternative to cut (and sometimes awk)";
      }
    
      {
        repo = "github.com/savedra1/clipse";
        name = "clipse";
        provider = "github";
        tags = [ "other" ];
        description = "Configurable TUI clipboard manager for Unix";
      }
    
      {
        repo = "github.com/cloudflare/cloudflared";
        name = "cloudflared";
        provider = "github";
        tags = [ "net" ];
        description = "Cloudflare Tunnel client";
      }
    
      {
        repo = "github.com/openai/codex";
        name = "codex";
        provider = "github";
        tags = [ "other" ];
        description = "Lightweight coding agent that runs in your terminal";
      }
    
      {
        repo = "github.com/charmbracelet/crush";
        name = "crush";
        provider = "github";
        tags = [ "other" ];
        description = "Glamourous agentic coding for all 💘";
      }
    
      {
        repo = "github.com/dandavison/delta";
        name = "delta";
        provider = "github";
        tags = [ "default" ];
        description = "A syntax-highlighting pager for git, diff, grep, rg --json, and blame output";
      }
    
      {
        repo = "github.com/jetify-com/devbox";
        name = "devbox";
        provider = "github";
        tags = [ "default" ];
        description = "Instant, easy, and predictable development environments";
      }
    
      {
        repo = "github.com/oug-t/difi";
        name = "difi";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/direnv/direnv";
        name = "direnv";
        provider = "github";
        tags = [ "default" ];
        description = "unclutter your .profile";
      }
    
      {
        repo = "github.com/sigoden/dufs";
        name = "dufs";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/chojs23/ec";
        name = "ec";
        provider = "github";
        tags = [ "other" ];
        description = "Easy terminal-native 3-way git mergetool vim-like workflow";
      }
    
      {
        repo = "github.com/Gentleman-Programming/engram";
        name = "engram";
        provider = "github";
        tags = [ "other" ];
        description = "Persistent memory system for AI coding agents. Agent-agnostic Go binary with SQLite + FTS5, MCP server, HTTP API, CLI, and TUI.";
      }
    
      {
        repo = "github.com/eza-community/eza";
        name = "eza";
        provider = "github";
        tags = [ "default" ];
        description = "A modern alternative to ls";
      }
    
      {
        repo = "github.com/cli/cli";
        name = "gh";
        provider = "github";
        tags = [ "other" "git" ];
        description = "GitHub’s official command line tool";
      }
    
      {
        repo = "github.com/dlvhdr/gh-dash";
        name = "gh-dash";
        provider = "github";
        tags = [ "other" ];
        description = "A rich terminal UI for GitHub that doesn't break your flow.";
      }
    
      {
        repo = "github.com/orhun/git-cliff";
        name = "git-cliff";
        provider = "github";
        tags = [ "default" "git" ];
        description = "A highly customizable Changelog Generator that follows Conventional Commit specifications ⛰️";
      }
    
      {
        repo = "github.com/gittower/git-flow-next";
        name = "git-flow";
        provider = "github";
        tags = [ "default" "git" ];
        description = "A modern reimplementation of git-flow in Go that offers greater flexibility while maintaining backward compatibility with the original git-flow and git-flow-avh.";
      }
    
      {
        repo = "github.com/git-town/git-town";
        name = "git-town";
        provider = "github";
        tags = [ "git" ];
        description = "Git branches made easy";
      }
    
      {
        repo = "github.com/sinclairtarget/git-who";
        name = "git-who";
        provider = "github";
        tags = [ "other" ];
        description = "Git blame for file trees";
      }
    
      {
        repo = "github.com/babarot/gomi";
        name = "gomi";
        provider = "github";
        tags = [ "default" ];
        description = "🗑️ Your UNIX rm command with a safety net!";
      }
    
      {
        repo = "github.com/aaif-goose/goose";
        name = "goose";
        provider = "github";
        tags = [ "other" ];
        description = "an open source, extensible AI agent that goes beyond code suggestions - install, execute, edit, and test with any LLM";
      }
    
      {
        repo = "github.com/charmbracelet/gum";
        name = "gum";
        provider = "github";
        tags = [ "default" ];
        description = "A tool for glamorous shell scripts 🎀";
      }
    
      {
        repo = "github.com/home-assistant/cli";
        name = "ha";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/TStansel/handoff";
        name = "handoff";
        provider = "github";
        tags = [ "other" ];
        description = "Handoff context from one agent to another agent";
      }
    
      {
        repo = "github.com/termworks/hexe";
        name = "hexe";
        provider = "github";
        tags = [ "default" ];
        description = "terminal multiplexer based on libghostty";
      }
    
      {
        repo = "github.com/github/hub";
        name = "hub";
        provider = "github";
        tags = [ "default" ];
        description = "A command-line tool that makes git easier to use with GitHub.";
      }
    
      {
        repo = "github.com/gohugoio/hugo";
        name = "hugo";
        provider = "github";
        tags = [ "other" ];
        description = "The world’s fastest framework for building websites.";
      }
    
      {
        repo = "github.com/pythops/impala";
        name = "impala";
        provider = "github";
        tags = [ "other" ];
        description = "🛜 TUI for managing wifi on Linux";
      }
    
      {
        repo = "github.com/ipinfo/cli";
        name = "ipinfo";
        provider = "github";
        tags = [ "default" ];
      }
    
      {
        repo = "github.com/jj-vcs/jj";
        name = "jj";
        provider = "github";
        tags = [ "default" "git" ];
      }
    
      {
        repo = "github.com/casey/just";
        name = "just";
        provider = "github";
        tags = [ "default" ];
        description = "🤖 Just a command runner";
      }
    
      {
        repo = "github.com/lockbook/lockbook";
        name = "lockbook";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/rust-lang/mdBook";
        name = "mdbook";
        provider = "github";
        tags = [ "default" ];
        description = "Create book from markdown files. Like Gitbook but implemented in Rust";
      }
    
      {
        repo = "github.com/mamba-org/micromamba-releases";
        name = "micromamba";
        provider = "github";
        tags = [ "default" ];
        description = "Micromamba executables mirrored from conda-forge as Github releases";
      }
    
      {
        repo = "github.com/bresilla/midy";
        name = "midy";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/charmbracelet/mods";
        name = "mods";
        provider = "github";
        tags = [ "other" ];
        description = "AI on the command line";
      }
    
      {
        repo = "github.com/fnichol/names";
        name = "names";
        provider = "github";
        tags = [ "other" ];
        description = "Random name generator for Rust";
      }
    
      {
        repo = "github.com/netbirdio/netbird";
        name = "netbird";
        provider = "github";
        tags = [ "default" ];
        description = "Connect your devices into a secure WireGuard®-based overlay network with SSO, MFA and granular access controls.";
      }
    
      {
        repo = "github.com/fosrl/newt";
        name = "newt";
        provider = "github";
        tags = [ "net" ];
        description = "Pangolin tunneled site & network connector";
      }
    
      {
        repo = "github.com/guyfedwards/nom";
        name = "nom";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/pokanop/nostromo";
        name = "nostromo";
        provider = "github";
        tags = [ "other" ];
        description = "👽 CLI for building powerful aliases and tools";
      }
    
      {
        repo = "github.com/opencloud-eu/opencloud";
        name = "oc";
        provider = "github";
        tags = [ "other" ];
        description = "🌤️ OpenCloud is the open source platform for file management, sharing and collaboration. Simple and sovereign.";
      }
    
      {
        repo = "github.com/ollama/ollama";
        name = "ollama";
        provider = "github";
        tags = [ "other" ];
        description = "Get up and running with Kimi-K2.6, GLM-5.1, MiniMax, DeepSeek, gpt-oss, Qwen, Gemma and other models.";
      }
    
      {
        repo = "github.com/fosrl/olm";
        name = "olm";
        provider = "github";
        tags = [ "net" ];
        description = "A remote access machine VPN client for Pangolin";
      }
    
      {
        repo = "github.com/anomalyco/opencode";
        name = "opencode";
        provider = "github";
        tags = [ "other" ];
        description = "The open source coding agent.";
      }
    
      {
        repo = "github.com/zjrosen/perles";
        name = "perles";
        provider = "github";
        tags = [ "other" ];
        description = "A BQL (Beads Query Language) search, dependency and multi-view kanban board Terminal UI for Beads issue tracking and multi-agent orchestration control plane workflow runner.";
      }
    
      {
        repo = "github.com/jacek-kurlit/pik";
        name = "pik";
        provider = "github";
        tags = [ "other" ];
        description = "Process Interactive Kill";
      }
    
      {
        repo = "github.com/prefix-dev/pixi";
        name = "pixi";
        provider = "github";
        tags = [ "default" ];
        description = "Powerful system-level package manager for Linux, macOS and Windows written in Rust – building on top of the Conda ecosystem.";
      }
    
      {
        repo = "github.com/mfontanini/presenterm";
        name = "presenterm";
        provider = "github";
        tags = [ "other" ];
        description = "A markdown terminal slideshow tool";
      }
    
      {
        repo = "github.com/lotabout/rargs";
        name = "rargs";
        provider = "github";
        tags = [ "other" ];
        description = "xargs + awk with pattern matching support. `ls *.bak | rargs -p '(.*)\\.bak' mv {0} {1}`";
      }
    
      {
        repo = "github.com/rerun-io/rerun";
        name = "rerun";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/bee-san/RustScan";
        name = "rustscan";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/matheus-git/systemd-manager-tui";
        name = "sdt";
        provider = "github";
        tags = [ "other" ];
        description = "A TUI application for managing systemd services.";
      }
    
      {
        repo = "github.com/sentrux/sentrux";
        name = "sentrux";
        provider = "github";
        tags = [ "other" ];
        description = "Real-time architectural sensor that helps AI agents close the feedback loop, enabling recursive self-improvement of code quality. Pure Rust.";
      }
    
      {
        repo = "github.com/servicer-labs/servicer";
        name = "ser";
        provider = "github";
        tags = [ "other" ];
        description = "A CLI to simplify service management on systemd";
      }
    
      {
        repo = "github.com/yassinebridi/serpl";
        name = "serpl";
        provider = "github";
        tags = [ "other" ];
        description = "A simple terminal UI for search and replace, ala VS Code.";
      }
    
      {
        repo = "github.com/sourcegraph/sg";
        name = "sg";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/runkids/skillshare";
        name = "skillshare";
        provider = "github";
        tags = [ "other" ];
        description = "📚 Sync skills across all AI CLI tools with one command and simplify team sharing. Supporting Codex, Claude Code, OpenClaw & more";
      }
    
      {
        repo = "github.com/charmbracelet/soft-serve";
        name = "soft";
        provider = "github";
        tags = [ "other" ];
        description = "The mighty, self-hostable Git server for the command line🍦";
      }
    
      {
        repo = "github.com/Spotifyd/spotifyd";
        name = "spotifyd";
        provider = "github";
        tags = [ "other" ];
        description = "A spotify daemon";
      }
    
      {
        repo = "github.com/sheepla/srss";
        name = "srss";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/starship/starship";
        name = "starship";
        provider = "github";
        tags = [ "default" ];
      }
    
      {
        repo = "github.com/smallstep/cli";
        name = "step";
        provider = "github";
        tags = [ "other" ];
        description = "🧰  A zero trust swiss army knife for working with X509, OAuth, JWT, OATH OTP, etc.";
      }
    
      {
        repo = "github.com/zircote/subcog";
        name = "subcog";
        provider = "github";
        tags = [ "other" ];
        description = "Persistent memory system for AI coding assistants.";
      }
    
      {
        repo = "github.com/matheus-git/systemd-manager-tui";
        name = "systemd-manager-tui";
        provider = "github";
        tags = [ "other" ];
        description = "A TUI application for managing systemd services.";
      }
    
      {
        repo = "github.com/austinjones/tab-rs";
        name = "tab";
        provider = "github";
        tags = [ "default" ];
        description = "The intuitive, config-driven terminal multiplexer designed for software & systems engineers";
      }
    
      {
        repo = "github.com/tealdeer-rs/tealdeer";
        name = "tldr";
        provider = "github";
        tags = [ "default" ];
        description = "A very fast implementation of tldr in Rust.";
      }
    
      {
        repo = "github.com/tree-sitter/tree-sitter";
        name = "tree-sitter";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/trunk-rs/trunk";
        name = "trunk";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/scipenai/tylax";
        name = "tylax";
        provider = "github";
        tags = [ "other" ];
        description = "A bi-directional converter between Typst and LaTeX. Available as both a CLI tool and a Web interface.";
      }
    
      {
        repo = "github.com/hyperb1iss/unifly";
        name = "unifly";
        provider = "github";
        tags = [ "other" "net" ];
        description = "🌐 Elegant UniFi network management CLI & TUI - for humans and agents";
      }
    
      {
        repo = "github.com/rustwasm/wasm-pack";
        name = "wasm-pack";
        provider = "github";
        tags = [ "other" ];
      }
    
      {
        repo = "github.com/sxyazi/yazi";
        name = "yazi";
        provider = "github";
        tags = [ "default" ];
        description = "💥 Blazing fast terminal file manager written in Rust, based on async I/O.";
      }
    
      {
        repo = "github.com/eclipse-zenoh/zenoh";
        name = "zenohd";
        provider = "github";
        tags = [ "default" ];
        description = "zenoh unifies data in motion, data in-use, data at rest and computations.";
      }
    
      {
        repo = "github.com/ajeetdsouza/zoxide";
        name = "zoxide";
        provider = "github";
        tags = [ "default" ];
        description = "A smarter cd command. Supports all major shells.";
      }
    
    ]
;
  };
}
