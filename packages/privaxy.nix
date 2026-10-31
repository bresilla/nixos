{ stdenv, fetchurl, unzip, autoPatchelfHook }:

# Not in nixpkgs; upstream's prebuilt headless binary only needs glibc.
stdenv.mkDerivation rec {
  pname = "privaxy";
  version = "0.5.2";
  src = fetchurl {
    url = "https://github.com/barre/privaxy/releases/download/v${version}/privaxy_nogui-${stdenv.hostPlatform.parsed.cpu.name}-unknown-linux-gnu.zip";
    hash = {
      x86_64-linux = "sha256-YErmMMs43UGMjVIsT424lFhiBPkD61C4UoJZL3p4NbU=";
      aarch64-linux = "sha256-G35z6Rd9oZBvtnAvE31K5p9yHbAZAuDjdT2K+YoKx68=";
    }.${stdenv.hostPlatform.system};
  };
  nativeBuildInputs = [ unzip autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];
  sourceRoot = ".";
  installPhase = "install -Dm755 privaxy $out/bin/privaxy";
  meta.mainProgram = "privaxy";
}
