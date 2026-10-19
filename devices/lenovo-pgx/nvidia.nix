# The GB10 needs a driver that knows it; nixpkgs' 595.71.05 drives it only as an
# "unsupported GPU", which CUDA refuses. 595.104.02 is the one graham33/nixos-dgx-spark ran.
# Both halves come from here: the open module (kernel/) and the libraries (default.nix).
nvidiaPackages:
nvidiaPackages.mkDriver {
  version = "595.104.02";
  sha256_aarch64 = "sha256-PafStmwNMufeDp3VtpTGGCoW+53Gor/mieO1m1pI7gI=";
  # x86 is never built for this machine.
  sha256_64bit = "sha256-PafStmwNMufeDp3VtpTGGCoW+53Gor/mieO1m1pI7gI=";
  openSha256 = "sha256-FWk5ra2yjz8VAxAA8GXrSoeBj/XC1BKvsKsBKR09joE=";
  persistencedSha256 = "sha256-JsMLPqJuZwAtHngsQODMsmgO7F2tVkQ2arc7fYa2bwo=";
  # The settings app is off on this machine.
  settingsSha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
}
