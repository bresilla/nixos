# Ollama's own ARM64 release, as DGX OS ran it: the binary with its bundled CUDA runtime
# (cuda_v12, cuda_v13), linked to this system and to the NVIDIA driver at runtime. Nothing
# compiles; nixpkgs has no cached CUDA build of Ollama.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  zstd,
  vulkan-loader,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "ollama-cuda-bin";
  version = "0.40.6";

  src = fetchurl {
    url = "https://github.com/ollama/ollama/releases/download/v${finalAttrs.version}/ollama-linux-arm64.tar.zst";
    sha256 = "17xvb722y43acwq3pyl56m1lihdjb6qg7pbxvdpv05xd52a9s9qa";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
    zstd
  ];
  buildInputs = [
    stdenv.cc.cc.lib
    vulkan-loader
  ];
  # The driver's libraries come from /run/opengl-driver at runtime.
  autoPatchelfIgnoreMissingDeps = [
    "libcuda.so.1"
    "libnvidia-ml.so.1"
  ];

  unpackPhase = ''
    tar --zstd -xf $src
  '';

  installPhase = ''
    mkdir -p $out
    cp -r bin lib $out/
    wrapProgram $out/bin/ollama --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib
  '';

  meta = {
    description = "Ollama's ARM64 release with its bundled CUDA runtime";
    homepage = "https://github.com/ollama/ollama";
    license = lib.licenses.unfreeRedistributable;
    mainProgram = "ollama";
    platforms = [ "aarch64-linux" ];
  };
})
