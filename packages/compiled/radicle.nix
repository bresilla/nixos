# Radicle's rad, git-remote-rad and radicle-node. nixpkgs flags 1.x insecure for
# private repositories only (peer traffic is not encrypted), so Hydra does not
# build it; this builds it once for the cache.
{ radicle-node }:
radicle-node.overrideAttrs (previous: {
  # The CLI fixture races seed discovery and asserts the resulting status text.
  checkFlags = previous.checkFlags ++ [
    "--skip=commands::patch::rad_patch_merge_unauthorized_branch"
  ];
})
