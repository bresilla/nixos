{ lib, stdenv, iio-sensor-proxy }:

# The Fairphone 6's rotation: Android-style orientation from its Qualcomm sensors.
iio-sensor-proxy.overrideAttrs (old: {
  version = "${old.version}-fp6-android";
  __intentionallyOverridingVersion = true;
  patches = (old.patches or [ ]) ++ [ ./iio-android-rotation.patch ];
  postPatch = (old.postPatch or "") + ''
    cp ${./orientation-filter.h} src/fp6-orientation-filter.h
  '';
  postBuild =
    (old.postBuild or "")
    + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      $CC -std=c11 -Wall -Wextra -Werror -O2 \
        -I ../src ${./orientation-filter.c} -lm -o test-fp6-orientation
      ./test-fp6-orientation
    '';
})
