# Throwaway container that tries out a container setup before the real ones get it.
{ pkgs, ... }:
{
  hive.containerNet.probe = { host = "10.231.9.1"; local = "10.231.9.2"; };
  networking.nat = { enable = true; internalInterfaces = [ "ve-probe" ]; externalInterface = "enp4s0"; };

  containers.probe = {
    autoStart = true;
    privateUsers = 524288;
    extraFlags = [ "--private-users-ownership=auto" ];
    privateNetwork = true;
    config = {
      system.stateVersion = "26.05";
      networking.firewall.enable = false;
      networking.useHostResolvConf = false;
      networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
      environment.systemPackages = [ pkgs.perl ];
      # Builders per system, as the builders page will write them.
      systemd.services.probe-machines = {
        wantedBy = [ "multi-user.target" ];
        after = [ "builder-key.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          cat > /var/lib/ci/machines <<'EOF'
          ssh-ng://nix-ssh@100.68.8.159 x86_64-linux /var/lib/ci/builder_ed25519 4 1 big-parallel,kvm,nixos-test,benchmark - c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUQ0Tmh2K1c3dVZQVHU3SXQ5WkdlTWRKdk11QWwva3dvU1Y1dVhxWVVCS0Q=
          ssh-ng://nix-ssh@100.68.93.181 aarch64-linux /var/lib/ci/builder_ed25519 4 1 big-parallel,kvm,nixos-test,benchmark - c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUdnbUk0b1EyM0srZDBxOTdVUk9zVndqcEZpdnNPUjNFa3N3TUFTSUdSMXQ=
          EOF
        '';
      };
    };
  };
}
