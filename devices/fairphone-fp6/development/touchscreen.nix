{ runCommand, gnumake, llvmPackages, kernelDev, kernelSource, modDirVersion }:

# Build just the touchscreen module against an existing FP6 kernel's headers.
# This is an explicit development step; normal updates reuse the output.
runCommand "fp6-touchscreen-${modDirVersion}" {
  nativeBuildInputs = [ gnumake llvmPackages.llvm ];
  allowedReferences = [ ];
} ''
  headers=${kernelDev}/lib/modules/${modDirVersion}/build
  test "$(cat "$headers/include/config/kernel.release")" = ${modDirVersion}
  cp ${kernelSource}/drivers/input/touchscreen/eswin_eph8621.c .
  printf 'obj-m += eswin_eph8621.o\n' > Makefile
  make -C "$headers" M="$PWD" ARCH=arm64 LLVM=1 \
    CC=${llvmPackages.clang-unwrapped}/bin/clang \
    LD=${llvmPackages.lld}/bin/ld.lld modules
  # Debug paths would otherwise retain the PC's complete kernel headers.
  llvm-strip --strip-debug eswin_eph8621.ko
  mkdir -p "$out/lib/modules/${modDirVersion}/extra"
  cp eswin_eph8621.ko "$out/lib/modules/${modDirVersion}/extra/"
''
