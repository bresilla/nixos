{ lib, linuxKernel, runCommand, llvmPackages, buildPackages, src, pmaports,
  features ? { }, kernelPatches ? [ ], randstructSeed ? "" }:

let
  makefile = builtins.readFile (src + "/Makefile");
  number = key:
    let line = lib.findFirst (lib.hasPrefix "${key} =") (throw "Missing ${key} in kernel Makefile") (lib.splitString "\n" makefile);
    in lib.trim (lib.removePrefix "${key} =" line);
  version = "${number "VERSION"}.${number "PATCHLEVEL"}.${number "SUBLEVEL"}${number "EXTRAVERSION"}";
  base = pmaports;
  parseLine = line:
    let match = builtins.match "(CONFIG_[^=]+)=([ym])" line;
    in lib.optional (match != null) { name = builtins.elemAt match 0; value = builtins.elemAt match 1; };
  overrides = {
    DMIID = "y";
    LOCALVERSION_AUTO = "n";
    TOUCHSCREEN_ESWIN_EPH8621 = "m";
  };
  configfile = runCommand "fp6-kernel-config" { } ''
    cat ${base} > "$out"
    cat >> "$out" <<'EOF'
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: "CONFIG_${name}=${value}") overrides)}
    EOF
  '';
in
(linuxKernel.manualConfig {
  inherit lib src version configfile features kernelPatches randstructSeed;
  modDirVersion = version;
  config = (builtins.listToAttrs (lib.concatMap parseLine (lib.splitString "\n" (builtins.readFile base))))
    // lib.mapAttrs' (name: value: lib.nameValuePair "CONFIG_${name}" value) overrides;
  # Keep the FP6 driver configuration for native and development cross-builds.
  stdenv = llvmPackages.stdenv;
  extraMakeFlags = [
    "LLVM=1"
    "LD=${lib.getExe' buildPackages.llvmPackages.lld "ld.lld"}"
    "HOSTCC=${lib.getExe' buildPackages.buildPackages.llvmPackages.clang "clang"} -fuse-ld=lld -Wno-unused-command-line-argument"
    "HOSTCXX=${lib.getExe' buildPackages.buildPackages.llvmPackages.clang "clang++"} -fuse-ld=lld -Wno-unused-command-line-argument"
    "HOSTLDFLAGS=-Wl,-rpath,${lib.makeLibraryPath (with buildPackages; [ openssl elfutils zlib zstd ])}"
  ]
    ++ map (tool: "${tool.make}=${lib.getExe' buildPackages.llvmPackages.llvm tool.bin}") [
      { make = "AR"; bin = "llvm-ar"; }
      { make = "NM"; bin = "llvm-nm"; }
      { make = "STRIP"; bin = "llvm-strip"; }
      { make = "OBJCOPY"; bin = "llvm-objcopy"; }
      { make = "OBJDUMP"; bin = "llvm-objdump"; }
      { make = "READELF"; bin = "llvm-readelf"; }
    ];
}).overrideAttrs (old: {
  # Kernel build tools run on the build host, including when cross-compiling.
  nativeBuildInputs = old.nativeBuildInputs ++ [ buildPackages.llvmPackages.lld ];
  depsBuildBuild = old.depsBuildBuild ++ [ buildPackages.buildPackages.llvmPackages.clang ];
})
