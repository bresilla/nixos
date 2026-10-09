{
  # VPN and local-VM addresses only; none are reachable from the internet.
  networking.extraHosts = ''
    169.254.171.45    game.thunder
    192.168.100.208   crux.virt
    192.168.100.163   nixo.virt
    100.98.150.84     skvm.tailscale
    100.68.45.87      game.netbird
    100.68.189.126    herz.netbird
    100.68.204.82     dump.netbird
    100.68.228.168    hive.netbird
    100.68.66.223     grid.netbird
    100.68.8.159      tron.netbird
    100.68.187.100    surf.netbird
    100.68.168.31     fair.netbird
    100.68.127.251    rasp.netbird
    100.68.185.7      edge.netbird
    172.30.0.190      husky.zerotier
    172.30.0.193      hashtag.zerotier
    172.30.0.248      orin.zerotier
    172.30.0.173      ceol.zerotier
    172.30.0.24       mini.zerotier
    172.30.0.137      oxbo.zerotier
    172.30.0.178      vbti.zerotier
  '';
}
