# searx: bresilla's fork of RustXNG, a SearXNG-compatible metasearch engine in Rust.
# One binary with its settings, templates and assets inside; the database engines are left out.
{ lib, rustPlatform, fetchFromGitHub }:
rustPlatform.buildRustPackage {
  pname = "searx";
  version = "0.32.0-unstable-2026-11-27-yt";
  src = fetchFromGitHub {
    owner = "bresilla";
    repo = "searx";
    rev = "5409a340e1d1a63305704e7e9002a2692a9009bc";
    hash = "sha256-2px8oAWArecutIYleIikUHGptK3Lu72z9514qBQ9KsI=";
  };
  cargoHash = "sha256-5sO0vDE//bo/bbcfBmwacDrXy/54iJfhlS5L2dhp020=";
  buildNoDefaultFeatures = true;
  # Its tests query live search providers.
  doCheck = false;
  meta = {
    description = "SearXNG-compatible metasearch engine in Rust";
    homepage = "https://github.com/bresilla/searx";
    license = lib.licenses.agpl3Plus;
    mainProgram = "searx";
    platforms = lib.platforms.linux;
  };
}
