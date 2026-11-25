# skill.bresilla.com on hive: the skills repository as public, read-only pages, out
# through the Cloudflare tunnel. The container keeps nothing worth backing up; it
# clones the repository again from gitea when its state is gone.
{ config, lib, bresilla, ... }:
let
  cfg = config.bresilla.server.skill;
  domain = "skill.bresilla.com";
  hostAddress = "10.231.9.1";
  address = "10.231.9.2";
in {
  options.bresilla.server.skill.enable = lib.mkEnableOption "the skills page, skill.bresilla.com";
  config = lib.mkIf cfg.enable {
    bresilla.server.containers = [ "skill" ];
    bresilla.server.tunnel.ingress.${domain} = "http://${address}:8080";
    # Outbound only (the repository on gitea); nothing outside hive opens a connection to it.
    networking.nat = { enable = true; internalInterfaces = [ "ve-skill" ]; };
    bresilla.server.containerNet.skill = { host = hostAddress; local = address; };

    containers.skill = {
      autoStart = true;
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      config = {
        imports = [ ./. ];
        bresilla.services.skill = {
          inherit domain;
          repo = "https://git.bresilla.com/bresilla/skills.git";
          skillshare = bresilla.skillshare;
        };
      };
    };
  };
}
