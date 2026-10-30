# NVIDIA Jetson support (JetPack 5–7) for this board only: kernel, firmware, CUDA and
# the flash scripts. Fetched by commit, so only orin ever downloads it.
builtins.getFlake "git+https://github.com/anduril/jetpack-nixos?rev=7fde791978b0b476abda2a6fc9b96d813d39c640&shallow=1"
