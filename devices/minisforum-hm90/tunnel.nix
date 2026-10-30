{
  # Cloudflare tunnel "hive-nix", configured only from here; each service adds its own hostnames to ingress.
  # The credentials file is a secret kept only on hive, never in git.
  services.cloudflared = {
    enable = true;
    tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de" = {
      credentialsFile = "/var/lib/cloudflared-hive-nix.json";
      default = "http_status:404";
      # The binary cache runs on nest; hive forwards to it over the direct link.
      ingress."cache.bresilla.com" = "http://10.99.0.2:8080";
    };
  };
}
