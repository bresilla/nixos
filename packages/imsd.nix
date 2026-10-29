{
  lib,
  llvmPackages_21,
  fetchgit,
  pkg-config,
  glib,
  pipewire,
  vo-amrwbenc,
  opencore-amr,
}:
llvmPackages_21.libcxxStdenv.mkDerivation {
  pname = "imsd";
  version = "1.0.0-unstable-2026-10-15";
  src = fetchgit {
    url = "https://forgejo.catcrafts.net/Catcrafts/imsd.git";
    rev = "2b5de7a60b3d9ecedab5fa34da40b2d3c8b26cab";
    hash = "sha256-lNdyNfZeTBEZSMjzNxHdhxMcu9b3Uq2q20lL1KahSoY=";
  };
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ glib ];
  strictDeps = true;
  # glibc's fortified inline stdio wrappers cannot be exported by std.cppm.
  hardeningDisable = [ "fortify" ];

  postPatch = ''
    substituteInPlace implementations/media.cpp \
      --replace-fail '"libvo-amrwbenc.so.0"' '"${vo-amrwbenc}/lib/libvo-amrwbenc.so.0"' \
      --replace-fail '"libopencore-amrnb.so.0"' '"${opencore-amr}/lib/libopencore-amrnb.so.0"' \
      --replace-fail '"libopencore-amrwb.so.0"' '"${opencore-amr}/lib/libopencore-amrwb.so.0"' \
      --replace-fail 'play ? "pw-play" : "pw-record"' 'play ? "${pipewire}/bin/pw-play" : "${pipewire}/bin/pw-record"'
    substituteInPlace implementations/main.cpp \
      --replace-fail /usr/libexec/imsd-media "$out/bin/imsd-media"
    substituteInPlace packaging/ims-pdn-up.sh \
      --replace-fail /usr/libexec/imsd-pcscf "$out/bin/imsd-pcscf"
  '';

  # Build the upstream C++ module graph directly, without a Flatpak SDK.
  # Every consumer must use the same flags as the standard-library module.
  buildPhase = ''
    runHook preBuild
    mkdir build
    flags=(-std=c++2c -stdlib=libc++ -O2 -fprebuilt-module-path="$PWD/build")
    gioFlags=($(pkg-config --cflags-only-I gio-2.0))
    gioLibs=($(pkg-config --libs-only-L --libs-only-l gio-2.0))
    $CXX "''${flags[@]}" --precompile ${llvmPackages_21.libcxx}/share/libc++/v1/std.cppm -o build/std.pcm
    flags+=(-fmodule-file=std="$PWD/build/std.pcm")
    $CXX "''${flags[@]}" -c build/std.pcm -o build/std.o
    core=(build/std.o)
    for part in Util Sip Sdp Aka Ipsec Qmi Messages Engine; do
      $CXX "''${flags[@]}" --precompile interfaces/Imsd-$part.cppm -o build/Imsd-$part.pcm
      flags+=(-fmodule-file=Imsd:$part="$PWD/build/Imsd-$part.pcm")
      $CXX "''${flags[@]}" -c build/Imsd-$part.pcm -o build/Imsd-$part.o
      core+=(build/Imsd-$part.o)
    done
    $CXX "''${flags[@]}" --precompile interfaces/Imsd.cppm -o build/Imsd.pcm
    flags+=(-fmodule-file=Imsd="$PWD/build/Imsd.pcm")
    $CXX "''${flags[@]}" -c build/Imsd.pcm -o build/Imsd.o
    core+=(build/Imsd.o)
    $CXX "''${flags[@]}" "''${gioFlags[@]}" --precompile interfaces/ImsdBus.cppm -o build/ImsdBus.pcm
    flags+=(-fmodule-file=ImsdBus="$PWD/build/ImsdBus.pcm")
    $CXX "''${flags[@]}" -c build/ImsdBus.pcm -o build/ImsdBus.o
    $CXX "''${flags[@]}" "''${gioFlags[@]}" implementations/main.cpp "''${core[@]}" build/ImsdBus.o "''${gioLibs[@]}" -lpthread -o build/imsd
    $CXX "''${flags[@]}" implementations/media.cpp build/std.o -ldl -lpthread -o build/imsd-media
    $CXX "''${flags[@]}" implementations/pcscf.cpp "''${core[@]}" -o build/imsd-pcscf
    $CXX "''${flags[@]}" "''${gioFlags[@]}" implementations/ofonod.cpp build/std.o build/ImsdBus.o "''${gioLibs[@]}" -o build/imsd-ofonod
    runHook postBuild
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    for suite in Util Aka Ipsec Qmi Messages Engine Sip Sdp; do
      $CXX "''${flags[@]}" tests/$suite/main.cpp "''${core[@]}" -o build/test-$suite
      build/test-$suite
    done
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 -t "$out/bin" build/imsd build/imsd-media build/imsd-pcscf build/imsd-ofonod
    install -Dm755 -t "$out/libexec" packaging/ims-pdn-up.sh
    install -Dm644 -t "$out/share/dbus-1/system.d" packaging/net.catcrafts.IMS1.conf packaging/org.ofono.conf
    install -Dm644 -t "$out/share/polkit-1/actions" packaging/net.catcrafts.IMS1.policy
    runHook postInstall
  '';
  meta = {
    description = "Native IMS/VoLTE calling and PipeWire media for the Fairphone 6";
    homepage = "https://forgejo.catcrafts.net/Catcrafts/imsd";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
}
