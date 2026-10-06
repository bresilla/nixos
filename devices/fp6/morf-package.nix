{ runCommand, python3, fetchurl, morf }:
let
  # These identify the reviewed shader change, not the application version.
  # The application's source/cache selection continues to follow upstream.
  before = fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/8a46f72ba16a8e96113519539846618a3a548f4e/crates/graphics/morf-render/src/field.wgsl";
    hash = "sha256-NmzOeKvYeDqFOHO1v496TlS2Bbb0syrAOk7EsRyjtjI=";
  };
  after = fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/f4be14ec36c43dc41385e974702b1090ac0ff9ea/crates/graphics/morf-render/src/field.wgsl";
    hash = "sha256-AUtzyBgZ6i3BKyfSjSkcc++ooGKqTqO7fbbeqUcx5Lw=";
  };
in runCommand "morf-fp6" {
  nativeBuildInputs = [ python3 ];
  meta = (morf.meta or { }) // { mainProgram = "morf"; };
} ''
  python3 ${./patch-morf.py} ${morf} "$out" ${before} ${after}
''
