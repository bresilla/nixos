{ config, pkgs, ... }:

let
  domain = "rad.bresilla.com";
  explorer = import ../../../shared/services/server/radicle { inherit pkgs domain; };
  identity = "/var/lib/radicle-identity";
  origin = "127.0.0.1:8316";
  httpd = "127.0.0.1:${toString config.services.radicle.httpd.listenPort}";
in {
  # This node is for public repositories. Radicle 1.x cannot protect private peer traffic.
  nixpkgs.config.permittedInsecurePackages = [ "radicle-node-1.10.3" ];

  services.radicle = {
    enable = true;
    package = pkgs.radicle-node.overrideAttrs (previous: {
      # The CLI fixture races seed discovery and asserts the resulting status text.
      checkFlags = previous.checkFlags ++ [
        "--skip=commands::patch::rad_patch_merge_unauthorized_branch"
      ];
    });
    publicKey = "${identity}/radicle.pub";
    node.listenAddress = "127.0.0.1";
    settings.node = {
      alias = "bresilla";
      seedingPolicy.default = "block";
    };
    httpd = {
      enable = true;
      listenPort = 8317;
    };
  };

  # A stable node identity outside the Nix store. Only the node gets the private key.
  systemd.services.radicle-identity = {
    description = "Initialize Hive's Radicle identity";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "radicle-identity";
      StateDirectoryMode = "0700";
      UMask = "0077";
    };
    script = ''
      key=${identity}/radicle
      if [ ! -s "$key" ]; then
        rm -f "$key.new" "$key.new.pub"
        ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "" -f "$key.new"
        mv "$key.new" "$key"
        rm -f "$key.new.pub"
      fi
      ${pkgs.openssh}/bin/ssh-keygen -y -f "$key" > "$key.pub.new"
      chmod 0644 "$key.pub.new"
      mv "$key.pub.new" "$key.pub"
    '';
  };

  systemd.services.radicle-node = {
    requires = [ "radicle-identity.service" ];
    after = [ "radicle-identity.service" ];
    serviceConfig.LoadCredential = [ "dev.radicle.node.secret:${identity}/radicle" ];
  };
  systemd.services.radicle-httpd = {
    requires = [ "radicle-node.service" ];
    after = [ "radicle-node.service" ];
  };

  services.caddy = {
    enable = true;
    virtualHosts."http://:8316".extraConfig = ''
      bind 127.0.0.1
      ${import ../../../shared/services/server/headers.nix}

      @raw path /raw /raw/*
      handle @raw {
        header Content-Security-Policy "sandbox; default-src 'none'"
        reverse_proxy ${httpd}
      }

      @backend {
        path /api /api/* /rad:*/* /*.git/* /*/info/refs /*/git-upload-pack
      }
      handle @backend {
        reverse_proxy ${httpd}
      }

      handle {
        root * ${explorer}
        try_files {path} /index.html
        file_server
      }
    '';
  };

  services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress.${domain} = "http://${origin}";
}
