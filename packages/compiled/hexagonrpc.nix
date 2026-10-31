{
  hexagonrpc,
  fetchFromGitHub,
}:
# FP6's sensor firmware creates and renames registry files. Upstream 0.4.0
# cannot serve those writes; pin the implementation tested on this phone.
hexagonrpc.overrideAttrs (_: {
  version = "0.4.0-fp6-writable-7f2fc1d";
  src = fetchFromGitHub {
    owner = "FadyAckad";
    repo = "hexagonrpc";
    rev = "7f2fc1d5afdd811416a4b1bb5664f2a932f7855f";
    hash = "sha256-MqNmKGyVAHpZcg2q9gPxEGgKgUSGDBJgB8e/Y24V5JA=";
  };
})
