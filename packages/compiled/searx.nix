# searx: bresilla's fork of RustXNG, a SearXNG-compatible metasearch engine in Rust.
# One binary with its settings, templates and assets inside; the database engines are left out.
{ lib, rustPlatform, fetchFromGitHub }:
rustPlatform.buildRustPackage {
  pname = "searx";
  version = "0.32.0-unstable-2026-11-27";
  src = fetchFromGitHub {
    owner = "bresilla";
    repo = "searx";
    rev = "0d6d41469d7c2614edcfdf1a7ec753ca98e6a7a9";
    hash = "sha256-W00jX4slP4OFvTtxge6IiUtkg01ieuyvYm/t7MRRO/M=";
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
