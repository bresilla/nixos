let
  devices = ../../devices;
  info = host: builtins.fromJSON (builtins.readFile (devices + "/${host}/device.json"));
  hosts = builtins.filter (host: builtins.pathExists (devices + "/${host}/device.json"))
    (builtins.attrNames (builtins.readDir devices));
  link = builtins.fromJSON (builtins.readFile (devices + "/nest/link.json"));
  netbird = host: (info host).netbird or null;
  # Every machine's NetBird address, from its device.json.
  machines = builtins.concatStringsSep "\n" (map (host: "${netbird host}    ${host}.netbird")
    (builtins.filter (host: netbird host != null) hosts));
  hive = netbird "hive";
in {
  # VPN and local-VM addresses only; none are reachable from the internet.
  networking.extraHosts = ''
    ${machines}
    ${link.hive}         hive.link
    ${link.nest}         nest.link

    # Machines outside devices/.
    169.254.171.45    game.thunder
    192.168.100.208   crux.virt
    192.168.100.163   nixo.virt
    100.98.150.84     skvm.tailscale
    100.68.45.87      game.netbird
    100.68.110.111    xper.netbird
    172.30.0.190      husky.zerotier
    172.30.0.193      hashtag.zerotier
    172.30.0.248      orin.zerotier
    172.30.0.173      ceol.zerotier
    172.30.0.24       mini.zerotier
    172.30.0.137      oxbo.zerotier
    172.30.0.178      vbti.zerotier

    # Services reached only over the overlay, by name from here and from no DNS.
    ${hive}    vault.bresilla.com
    ${hive}    cert.bresilla.com
    ${hive}    status.bresilla.com
    # Only over innernet: the server's own address in skynet0.
    10.20.0.1         net.bresilla.com
  '';
}
