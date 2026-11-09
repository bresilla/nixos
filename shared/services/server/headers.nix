# The same rules on every site's Caddy: only over HTTPS from now on, never inside
# another site's frame, no guessing of file types, no full address sent elsewhere.
# Set after the app answers, so they replace its own instead of doubling them.
''
  header {
    defer
    Strict-Transport-Security "max-age=63072000"
    X-Frame-Options DENY
    X-Content-Type-Options nosniff
    Referrer-Policy same-origin
  }
''
