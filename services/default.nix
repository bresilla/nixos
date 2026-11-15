# What a server hosts: each service is a NixOS container with its host side in
# <service>/host.nix, off until the machine enables it (bresilla.server.<service>).
# boundary/ is what every container on the machine shares. What every machine runs,
# server or not, lives in shared/services/ instead.
{
  imports = [
    ./boundary
    ./gitea/host.nix
    ./cache/host.nix
    ./tunnel/host.nix
    ./ci/host.nix
    ./id/host.nix
    ./s3/host.nix
    ./vault/host.nix
    ./ca/host.nix
    ./net/host.nix
  ];
}
