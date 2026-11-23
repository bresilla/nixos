# skillshare: syncs skills, agents, MCP servers and plugins to every AI CLI tool.
# Its go.mod wants Go 1.26.10, newer than nixos-26.05's, so unstable's Go builds it.
# The web UI is a separate release download the binary fetches itself.
{ lib, unstable }:
unstable.buildGoModule (final: {
  pname = "skillshare";
  version = "0.30.13";
  src = unstable.fetchFromGitHub {
    owner = "runkids";
    repo = "skillshare";
    rev = "v${final.version}";
    hash = "sha256-c3ehEa5U9o9Urmcjk9/deVjboWvcYpxkZqPUYsQtx8o=";
  };
  vendorHash = "sha256-mAfSa/IkHg/71YJvjiuQcgFAud7G362UimeuC3He0fo=";
  subPackages = [ "cmd/skillshare" ];
  env.CGO_ENABLED = 0;
  ldflags = [ "-s" "-w" "-X main.version=${final.version}" ];
  # Its tests drive git and the network.
  doCheck = false;
  meta = {
    description = "Sync skills, agents, MCP and plugins to all AI CLI tools";
    homepage = "https://github.com/runkids/skillshare";
    license = lib.licenses.mit;
    mainProgram = "skillshare";
  };
})
