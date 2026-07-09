{ lib
, cmake
, disko
, makeWrapper
, pkg-config
, pcsclite
, rustPlatform
}:

rustPlatform.buildRustPackage {
  pname = "nx-rs";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: type:
      let
        base = baseNameOf path;
      in
      !(type == "directory" && base == "target");
  };

  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [
    cmake
    makeWrapper
    pkg-config
  ];

  buildInputs = [
    pcsclite
  ];

  postInstall = ''
    wrapProgram $out/bin/nx-rs \
      --prefix PATH : ${lib.makeBinPath [ disko ]}
  '';
}
