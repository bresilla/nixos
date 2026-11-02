{ iptsd, lib, stdenv }:

# Keep pen rejection in iptsd's uinput path, with a configurable proximity-out delay.
iptsd.overrideAttrs (old: {
  version = "${old.version}-stylus-delay";
  __intentionallyOverridingVersion = true;
  # The upstream source uses finalAttrs.version in its tag; retain the original source.
  src = iptsd.src;
  patches = (old.patches or [ ]) ++ [ ./stylus-touch-delay.patch ];
  postPatch = (old.postPatch or "") + ''
    cp ${./stylus-touch-delay.hpp} src/apps/daemon/stylus-touch-delay.hpp
  '';
  postBuild = (old.postBuild or "")
    + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      $CXX -std=c++17 -Wall -Wextra -Werror -O2 \
        -I ../src/apps/daemon ${./test-stylus-touch-delay.cpp} -o test-stylus-touch-delay
      ./test-stylus-touch-delay
    '';
})
