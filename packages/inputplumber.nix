{ inputplumber, fetchFromGitHub, rustPlatform }:

# 0.80 added the AYN Odin 3 profile; nixpkgs 26.05 ships 0.78.
inputplumber.overrideAttrs (final: old: {
  version = "0.82.0";
  src = fetchFromGitHub {
    owner = "ShadowBlip";
    repo = "InputPlumber";
    tag = "v${final.version}";
    hash = "sha256-JG0NdKV8A77NkJr/2CiKAElrEzjto3xyzOODyRl1dZE=";
  };
  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (final) src;
    hash = "sha256-WW0OTz+pqy5mmLq+Afn/NhXmHrVtDOadTLMlGDJd3bw=";
  };
})
