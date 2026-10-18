{
  lib,
  llvmPackages_21,
  fetchgit,
  fetchFromGitHub,
  pkg-config,
  glib,
  dbus,
}:
let
  qcomtee = llvmPackages_21.stdenv.mkDerivation {
    pname = "fingerprintd-libqcomtee";
    version = "unstable-2026-07-25";
    src = fetchFromGitHub {
      owner = "quic";
      repo = "quic-teec";
      rev = "736419e25a2036aac3292a10a93e394a90750ca3";
      hash = "sha256-HVtw2RT3LxwcRifzX9XT7nNsWPCJesVbuAhjPSgscus=";
    };
    # Same subset as upstream fingerprintd's make-libqcomtee.sh. The daemon
    # constructs its own tested credential objects, so no QCBOR is needed.
    buildPhase = ''
      for file in libqcomtee/src/qcomtee_object.c libqcomtee/src/objects/mem_obj.c; do
        $CC -O2 -fPIC -Ilibqcomtee/include -Ilibqcomtee/src -c "$file" -o "$(basename "$file" .c).o"
      done
      $AR rcs libqcomtee.a *.o
    '';
    installPhase = ''
      mkdir -p "$out/lib" "$out/include"
      cp libqcomtee.a "$out/lib/"
      cp libqcomtee/include/*.h "$out/include/"
    '';
    meta.license = lib.licenses.bsd3;
  };
in
llvmPackages_21.libcxxStdenv.mkDerivation {
  pname = "fingerprintd";
  version = "0.2.6-unstable-2026-10-16";
  src = fetchgit {
    url = "https://forgejo.catcrafts.net/Catcrafts/fingerprintd.git";
    rev = "a4d5ed687749776fb0ef9cebe0de015bc2f8653b";
    hash = "sha256-S4tGr3DTIIkd+upxhdiDrJXPzhZWc3U4rE7mBpTJ0qM=";
  };
  nativeBuildInputs = [ pkg-config ];
  nativeCheckInputs = [ dbus ];
  buildInputs = [
    glib
    qcomtee
  ];
  strictDeps = true;
  # glibc's fortified inline stdio wrappers cannot be exported by std.cppm.
  hardeningDisable = [ "fortify" ];
  postPatch = ''
    substituteInPlace implementations/main.cpp \
      --replace-fail /lib/firmware/focal64.mbn /var/lib/fingerprintd/focal64.mbn \
      --replace-fail /lib/firmware/fingerprintd.json "$out/share/fingerprintd/fingerprintd.json"
    substituteInPlace packaging/net.reactivated.Fprint.service \
      --replace-fail /usr/bin/fingerprintd "$out/bin/fingerprintd" \
      --replace-fail ' --daemon' ' --daemon --standby-unlock=off'
    # Upstream checks ownership but does not yet enforce its enrollment
    # polkit action. Require root for changes; enrollment can use pkexec.
    # The existing root policy overrides these default-policy denials.
    # Match the daemon's sole device path, including calls without an interface.
    substituteInPlace packaging/net.reactivated.Fprint.conf \
      --replace-fail '<allow receive_sender="net.reactivated.Fprint"/>' \
      '<allow receive_sender="net.reactivated.Fprint"/>
       <deny send_destination="net.reactivated.Fprint" send_path="/net/reactivated/Fprint/Device/0" send_member="EnrollStart"/>
       <deny send_destination="net.reactivated.Fprint" send_path="/net/reactivated/Fprint/Device/0" send_member="DeleteEnrolledFingers"/>
       <deny send_destination="net.reactivated.Fprint" send_path="/net/reactivated/Fprint/Device/0" send_member="DeleteEnrolledFingers2"/>
       <deny send_destination="net.reactivated.Fprint" send_path="/net/reactivated/Fprint/Device/0" send_member="DeleteEnrolledFinger"/>'
  '';
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
    for part in Sfs Rpmb Ta Engine Store Tee Sensor Actions; do
      $CXX "''${flags[@]}" --precompile interfaces/Fingerprintd-$part.cppm -o build/Fingerprintd-$part.pcm
      flags+=(-fmodule-file=Fingerprintd:$part="$PWD/build/Fingerprintd-$part.pcm")
      $CXX "''${flags[@]}" -c build/Fingerprintd-$part.pcm -o build/Fingerprintd-$part.o
      core+=(build/Fingerprintd-$part.o)
    done
    $CXX "''${flags[@]}" --precompile interfaces/Fingerprintd.cppm -o build/Fingerprintd.pcm
    flags+=(-fmodule-file=Fingerprintd="$PWD/build/Fingerprintd.pcm")
    $CXX "''${flags[@]}" -c build/Fingerprintd.pcm -o build/Fingerprintd.o
    core+=(build/Fingerprintd.o)
    $CXX "''${flags[@]}" "''${gioFlags[@]}" implementations/main.cpp "''${core[@]}" \
      ${qcomtee}/lib/libqcomtee.a "''${gioLibs[@]}" -lpthread -o build/fingerprintd
    runHook postBuild
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    for suite in Sfs Rpmb Ta Engine Store Tee Sensor Actions; do
      $CXX "''${flags[@]}" tests/$suite/main.cpp "''${core[@]}" -o build/test-$suite
      build/test-$suite
    done
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 build/fingerprintd "$out/bin/fingerprintd"
    install -Dm644 packaging/fingerprintd.json "$out/share/fingerprintd/fingerprintd.json"
    install -Dm644 packaging/net.reactivated.Fprint.conf "$out/share/dbus-1/system.d/net.reactivated.Fprint.conf"
    install -Dm644 packaging/net.reactivated.Fprint.service "$out/share/dbus-1/system-services/net.reactivated.Fprint.service"
    install -Dm644 packaging/net.reactivated.fprint.device.policy "$out/share/polkit-1/actions/net.reactivated.fprint.device.policy"
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    test "$(id -u)" != 0
    busDir=$(mktemp -d)
    cleanupBus() {
      kill "$echoPid" "$busPid" 2>/dev/null || true
      rm -rf "$busDir"
    }
    cat > "$busDir/bus.conf" <<CONF
    <busconfig>
      <type>session</type>
      <listen>unix:tmpdir=$busDir</listen>
      <auth>EXTERNAL</auth>
      <policy context="default">
        <allow user="*"/>
        <allow send_destination="*"/>
        <allow receive_sender="*"/>
        <allow own="net.reactivated.Fprint"/>
      </policy>
      <include>$out/share/dbus-1/system.d/net.reactivated.Fprint.conf</include>
    </busconfig>
    CONF
    dbus-daemon --config-file="$busDir/bus.conf" --fork --print-address=1 --print-pid=1 > "$busDir/address"
    export DBUS_SESSION_BUS_ADDRESS=$(head -n1 "$busDir/address")
    busPid=$(tail -n1 "$busDir/address")
    dbus-test-tool echo --session --name=net.reactivated.Fprint > "$busDir/echo.log" 2>&1 &
    echoPid=$!
    trap cleanupBus EXIT
    for attempt in {1..50}; do
      if dbus-send --session --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
        string:net.reactivated.Fprint | grep -q 'boolean true'; then
        break
      fi
      sleep 0.1
    done
    for method in VerifyStart EnrollStart DeleteEnrolledFingers DeleteEnrolledFingers2 DeleteEnrolledFinger; do
      if dbus-send --session --print-reply --reply-timeout=2000 \
        --dest=net.reactivated.Fprint /net/reactivated/Fprint/Device/0 \
        "net.reactivated.Fprint.Device.$method" > "$busDir/reply" 2>&1; then
        test "$method" = VerifyStart
      else
        test "$method" != VerifyStart
        grep -q 'AccessDenied' "$busDir/reply"
      fi
      echo "D-Bus authorization: $method passed"
    done
    cleanupBus
    trap - EXIT
    runHook postInstallCheck
  '';
  meta = {
    description = "FocalTech FT9391 fingerprint support through Qualcomm TEE";
    homepage = "https://forgejo.catcrafts.net/Catcrafts/fingerprintd";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
}
