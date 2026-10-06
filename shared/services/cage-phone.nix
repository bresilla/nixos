{ cage }:
# Output power support: https://github.com/cage-kiosk/cage/pull/529
# The second patch adds the phone greeter's idle/power-key policy. It is only
# active with CAGE_PHONE_IDLE_SECONDS set; desktop sessions do not use it.
cage.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./cage-output-power.patch
    ./cage-phone-idle.patch
  ];
})
