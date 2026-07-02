# nix Worker

Cloudflare Worker for:

```sh
curl -fsSL https://nix.bresilla.dev | bash
```

Cloudflare setup:

1. In Workers & Pages, connect the GitHub repository.
2. Set root directory to `.cloudflare/nix`.
3. Use production branch `main`.
4. Leave build command empty.
5. Use deploy command `npx wrangler deploy`.

The Worker uses a Custom Domain:

```jsonc
"routes": [
  {
    "pattern": "nix.bresilla.dev",
    "custom_domain": true
  }
]
```

Do not add a manual DNS record for `nix.bresilla.dev`; Cloudflare creates and
manages it for the Worker Custom Domain.
