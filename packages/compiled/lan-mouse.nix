# lan-mouse 0.11 from unstable, which has the `daemon` and `cli` commands eva's
# settings page uses; its libgit2-sys wants the system libgit2.
{ unstable }:
unstable.lan-mouse.overrideAttrs (old: {
  buildInputs = (old.buildInputs or [ ]) ++ [ unstable.libgit2 ];
  # Captures only at the outermost edge of the whole layout, not at every screen whose
  # side is free: core's laptop screen sits in under two monitors and was an exit too.
  patches = (old.patches or [ ]) ++ [ ./lan-mouse-outer-edge.patch ];
})
