{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.bresilla.features;
  can = config.bresilla.services.socketcan;
  platformArchitecture =
    {
      "x86_64-linux" = "x86_64";
      "aarch64-linux" = "arm64";
      "riscv64-linux" = "riscv64";
    }
    .${pkgs.stdenv.hostPlatform.system} or "unknown";

  mkVcanNetdev =
    name: _:
    lib.nameValuePair "10-${name}" {
      netdevConfig = {
        Kind = "vcan";
        Name = name;
      };
    };

  mkVcanNetwork =
    name: _:
    lib.nameValuePair "10-${name}" {
      matchConfig.Name = name;
      linkConfig.ActivationPolicy = "always-up";
    };
in
{
  options.bresilla.features.system = {
    architecture = lib.mkOption {
      type = lib.types.enum [
        "x86_64"
        "arm64"
        "riscv64"
        "unknown"
      ];
      default = "unknown";
      description = "CPU architecture family for host-specific hardware behavior.";
    };
    cpuVendor = lib.mkOption {
      type = lib.types.enum [
        "intel"
        "amd"
        "arm"
        "unknown"
      ];
      default = "unknown";
      description = "CPU vendor/family for host-specific hardware behavior.";
    };
    nvidia = {
      enable = lib.mkEnableOption "Nvidia GPU driver support";
      open = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use Nvidia's open kernel module.";
      };
      prime = {
        offload.enable = lib.mkEnableOption "Nvidia PRIME render offload";
        intelBusId = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Intel iGPU PCI bus ID for PRIME, for example PCI:0:2:0.";
        };
        nvidiaBusId = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Nvidia dGPU PCI bus ID for PRIME, for example PCI:1:0:0.";
        };
      };
    };
    firmware.enable = lib.mkEnableOption "firmware updates";
    uinput.enable = lib.mkEnableOption "uinput support";
    tlp.enable = lib.mkEnableOption "TLP power management";
    laptopPower.enable = lib.mkEnableOption "laptop lid and power button policy";
    yubikey.enable = lib.mkEnableOption "YubiKey, smartcard, FIDO2, GPG, and SSH tooling";
    fingerprint.enable = lib.mkEnableOption "fingerprint authentication and enrollment";
    hardwareDev.enable = lib.mkEnableOption "hardware development device access and tooling";
  };

  options.bresilla.services.socketcan = {
    enable = lib.mkEnableOption "SocketCAN support" // {
      default = true;
    };

    virtualInterfaces = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.bitrate = lib.mkOption {
            type = lib.types.ints.positive;
            default = 250000;
            description = "Nominal CAN bitrate kept for matching real CAN defaults; virtual CAN does not use it.";
          };
        }
      );
      default = {
        vcan0 = { };
      };
      description = "Virtual CAN interfaces to create for testing.";
    };
  };

  config = lib.mkMerge [
    { bresilla.features.system.firmware.enable = lib.mkDefault true; }

    (lib.mkIf cfg.system.fingerprint.enable { services.fprintd.enable = true; })

    {
      assertions = [
        {
          assertion = !(cfg.system.cpuVendor == "arm" && cfg.system.architecture == "x86_64");
          message = "ARM CPU vendor cannot be used with x86_64 architecture.";
        }
        {
          assertion =
            !(
              (cfg.system.cpuVendor == "intel" || cfg.system.cpuVendor == "amd")
              && cfg.system.architecture != "x86_64"
            );
          message = "Intel/AMD microcode hosts must use x86_64 architecture in this config.";
        }
        {
          assertion = cfg.system.architecture == "unknown" || cfg.system.architecture == platformArchitecture;
          message = "bresilla.features.system.architecture must match the flake host platform.";
        }
        {
          assertion = cfg.system.nvidia.prime.offload.enable -> cfg.system.nvidia.prime.intelBusId != null;
          message = "Nvidia PRIME offload requires bresilla.features.system.nvidia.prime.intelBusId.";
        }
        {
          assertion = cfg.system.nvidia.prime.offload.enable -> cfg.system.nvidia.prime.nvidiaBusId != null;
          message = "Nvidia PRIME offload requires bresilla.features.system.nvidia.prime.nvidiaBusId.";
        }
      ];
    }

    (lib.mkIf (cfg.system.cpuVendor == "intel") {
      hardware.cpu.intel.updateMicrocode = true;
    })

    (lib.mkIf (cfg.system.cpuVendor == "amd") {
      hardware.cpu.amd.updateMicrocode = true;
    })

    (lib.mkIf cfg.system.uinput.enable {
      hardware.uinput.enable = true;
    })

    (lib.mkIf cfg.system.nvidia.enable {
      nixpkgs.config.allowUnfreePredicate =
        pkg:
        builtins.elem (lib.getName pkg) [
          "nvidia-x11"
          "nvidia-settings"
          "nvidia-persistenced"
        ];
      hardware.graphics.enable = true;
      services.xserver.videoDrivers = [ "nvidia" ];
      hardware.nvidia = {
        modesetting.enable = true;
        nvidiaSettings = false;
        open = cfg.system.nvidia.open;
        powerManagement = {
          enable = true;
          finegrained = cfg.system.nvidia.prime.offload.enable;
        };
      };
    })

    (lib.mkIf (cfg.system.nvidia.enable && cfg.system.nvidia.prime.offload.enable) {
      hardware.nvidia.prime = {
        offload = {
          enable = true;
          enableOffloadCmd = true;
        };
        intelBusId = cfg.system.nvidia.prime.intelBusId;
        nvidiaBusId = cfg.system.nvidia.prime.nvidiaBusId;
      };
      # Hyprland opens every GPU it finds; keep it off the dGPU so it can sleep.
      environment.sessionVariables.AQ_DRM_DEVICES = "/dev/dri/intel-igpu";
    })

    (lib.mkIf cfg.system.firmware.enable {
      services.fwupd.enable = true;
    })

    (lib.mkIf cfg.system.tlp.enable {
      services.tlp.enable = true;
      services.power-profiles-daemon.enable = false;
    })

    (lib.mkIf cfg.system.laptopPower.enable {
      # protectKernelImage adds nohibernate, contradicting HandlePowerKey.
      security.protectKernelImage = false;
      boot.kernel.sysctl."kernel.kexec_load_disabled" = lib.mkDefault true;
      services.logind.settings.Login = {
        HandleLidSwitch = "suspend";
        HandleLidSwitchExternalPower = "suspend";
        HandleLidSwitchDocked = "suspend";
        HandlePowerKey = "hibernate";
      };
    })

    (lib.mkIf cfg.system.yubikey.enable {
      services.pcscd.enable = true;

      programs.gnupg.agent = {
        enable = true;
        enableSSHSupport = true;
        pinentryPackage = if cfg.desktop.enable then pkgs.pinentry-gnome3 else pkgs.pinentry-curses;
      };

      environment.systemPackages =
        with pkgs;
        [
          gnupg
          libfido2
          opensc
          pam_u2f
          yubico-piv-tool
          yubikey-manager
          yubikey-personalization
          yubikey-touch-detector
        ]
        ++ lib.optionals cfg.desktop.enable [ yubioath-flutter ];
    })

    (lib.mkIf cfg.system.hardwareDev.enable {
      hardware.keyboard.qmk.enable = true;

      environment.systemPackages = with pkgs; [
        avrdude
        dfu-util
        openocd
        probe-rs-tools
        qmk
        stlink
      ];
    })

    # ddcutil needs i2c access to external monitors.
    (lib.mkIf (config.bresilla.programs.desktop.enable && config.bresilla.features.desktop.enable) {
      hardware.i2c.enable = true;
      users.users.${config.bresilla.user.name}.extraGroups = [ "i2c" ];
    })

    (lib.mkIf can.enable {
      boot.kernelModules = [ "vcan" ];
      environment.systemPackages = [ pkgs.can-utils ];

      systemd.network.enable = true;
      systemd.network.netdevs = lib.mapAttrs' mkVcanNetdev can.virtualInterfaces;
      systemd.network.networks = lib.mapAttrs' mkVcanNetwork can.virtualInterfaces;
    })
  ];
}
