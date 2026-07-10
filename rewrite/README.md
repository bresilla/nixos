# Rust Rewrite

This directory is the isolated Rust rewrite area.

The first target is `nox`, a Rust version of the current `nx` shell wrapper. It delegates destructive installer work to the existing shell scripts until each subsystem is rewritten and tested.

## Run

```bash
cargo run --manifest-path rewrite/Cargo.toml -- --help
cargo run --manifest-path rewrite/Cargo.toml -- status
```

## Current Scope

- `nox install`: delegates to `install.sh`.
- `nox generate`: applies the generated system flake through Rust command dispatch.
- `nox check`: evaluates the generated system flake through Rust command dispatch.
- `nox status`: runs `git status --short`.
- `nox edit`: opens a native terminal selector, discovers module files from the repo tree, then opens the selected file.
- YAML SOPS files selected through `nox edit` are decrypted and re-encrypted natively with the Rust `age` and `yubikey` crates.
- Non-YAML SOPS files still fall back to external `sops`.

The main help intentionally shows only the normal commands. Diagnostic commands such as `sops-info`, `sops-rule`, `nix-parse`, and `yubikey` are still callable while the rewrite is being built, but hidden from `--help`.

Selector keys:

- `up`/`down` or `j`/`k`: move.
- `/`: start a filter.
- `backspace`: edit filter.
- `enter`: select.
- `esc`: clear filter, then cancel.

Future work can move Disko, installer state, and the UI into Rust modules under this crate.
