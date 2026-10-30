# NixOS support for the DGX Spark (GB10): its module, kernel source and config, for
# lama only. Fetched by commit, so no other machine downloads it.
builtins.fetchGit {
  url = "https://github.com/graham33/nixos-dgx-spark";
  rev = "9c8131eeec3535a28aed136db7da464280d232ac";
  shallow = true;
}
