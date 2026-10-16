{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.isaacsim;
  # NVIDIA's standalone build stays outside the store; this gives it an Ubuntu-like root.
  isaacsim = pkgs.buildFHSEnv {
    name = "isaacsim";
    targetPkgs = pkgs: with pkgs; [
      alsa-lib
      bzip2
      cups
      dbus
      expat
      fontconfig
      freetype
      glib
      gtk3
      libdrm
      libgbm
      libGL
      libglvnd
      libpulseaudio
      libuuid
      libxkbcommon
      # Isaac Sim links libxml2.so.2; libxml2 2.14+ renamed it to .so.16.
      libxml2_13
      nspr
      nss
      openssl
      stdenv.cc.cc.lib
      udev
      vulkan-loader
      wayland
      zlib
      zstd
      libx11
      libxcomposite
      libxcursor
      libxdamage
      libxext
      libxfixes
      libxi
      libxinerama
      libxrandr
      libxrender
      libxscrnsaver
      libxt
      libxtst
      libxcb
      libsm
      libice
    ]
    # Isaac Sim reads the driver version from /usr/bin/nvidia-smi.
    ++ lib.optional config.bresilla.features.system.nvidia.enable config.hardware.nvidia.package.bin;
    profile = ''
      export VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json
      export __EGL_VENDOR_LIBRARY_DIRS=/run/opengl-driver/share/glvnd/egl_vendor.d
    '';
    runScript = "${cfg.path}/isaac-sim.sh";
  };
  # NVIDIA's post_install.sh would add a launcher for the bare isaac-sim.sh, outside the wrapper.
  desktopItem = pkgs.makeDesktopItem {
    name = "isaacsim";
    desktopName = "Isaac Sim";
    comment = "NVIDIA robotics simulator";
    exec = "isaacsim";
    icon = "${cfg.path}/data/icon/omni.isaac.sim.png";
    categories = [ "Development" "Science" ];
  };
in
{
  options.bresilla.programs.isaacsim = {
    enable = lib.mkEnableOption "NVIDIA Isaac Sim from its standalone build";
    path = lib.mkOption {
      type = lib.types.str;
      default = "/pkg/isaacsim/6.2.0";
      description = "Where the standalone Isaac Sim build is unpacked.";
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isx86_64) {
    environment.systemPackages = [ isaacsim desktopItem ];
  };
}
