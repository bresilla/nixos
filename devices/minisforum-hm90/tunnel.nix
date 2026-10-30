{
  # Cloudflare tunnel "hive"; each service adds its own hostnames to ingress.
  # The credentials file is a secret kept only on hive, never in git.
  services.cloudflared = {
    enable = true;
    tunnels."81359962-b6c3-4f3f-907c-502f41fe0711" = {
      credentialsFile = "/var/lib/cloudflared-hive.json";
      default = "http_status:404";
    };
  };
}
