{
  # VPN and local-VM addresses only; none are reachable from the internet.
  networking.extraHosts = ''
    169.254.171.45    game.thunder
    192.168.100.208   crux.virt
    192.168.100.163   nixo.virt
    100.98.150.84     skvm.tailscale
    100.68.45.87      game.netbird
    100.68.233.203    hive.netbird
    100.68.8.159      tron.netbird
    100.68.213.34     fair.netbird
    100.68.26.22      odin.netbird
    100.68.104.113    nest.netbird
    100.68.116.48     core.netbird
    100.68.110.111    xper.netbird
    100.68.0.73       nova.netbird
    100.68.139.145    edge.netbird
    172.30.0.190      husky.zerotier
    172.30.0.193      hashtag.zerotier
    172.30.0.248      orin.zerotier
    172.30.0.173      ceol.zerotier
    172.30.0.24       mini.zerotier
    172.30.0.137      oxbo.zerotier
    172.30.0.178      vbti.zerotier
  '';
}
