# lan-mouse 0.11 from unstable, which has the `daemon` and `cli` commands eva's
# settings page uses; its libgit2-sys wants the system libgit2.
{ unstable }:
unstable.lan-mouse.overrideAttrs (old: {
  buildInputs = (old.buildInputs or [ ]) ++ [ unstable.libgit2 ];
})
