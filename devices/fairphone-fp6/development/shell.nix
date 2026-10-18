{ pkgs }:
pkgs.mkShell {
  packages = with pkgs; [ android-tools dtc usbutils python3 git gnumake pkg-config llvmPackages.clang llvmPackages.lld ];
}
