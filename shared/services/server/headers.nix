# The same rules on every site's Caddy: only over HTTPS from now on, never inside
# another site's frame, no guessing of file types, no full address sent elsewhere.
''
  header {
    Strict-Transport-Security "max-age=63072000"
    X-Frame-Options DENY
    X-Content-Type-Options nosniff
    Referrer-Policy same-origin
  }
''
