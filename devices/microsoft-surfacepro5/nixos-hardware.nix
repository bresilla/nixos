# The Surface's linux-surface kernel, touch and thermal setup from nixos-hardware,
# for surf only. Fetched by commit, so no other machine downloads it.
builtins.fetchGit {
  url = "https://github.com/NixOS/nixos-hardware";
  rev = "04c6b94fa104bc23650983a4513aea196794d321";
  shallow = true;
}
