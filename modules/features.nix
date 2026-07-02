{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.features;
  platformArchitecture =
    {
      "x86_64-linux" = "x86_64";
      "aarch64-linux" = "arm64";
      "riscv64-linux" = "riscv64";
    }
    .${pkgs.stdenv.hostPlatform.system} or "unknown";
in
{
  options.bresilla.features = {
    network = {
      networkmanager.enable = lib.mkEnableOption "NetworkManager";
      bluetooth.enable = lib.mkEnableOption "Bluetooth";
      wifi = {
        enable = lib.mkEnableOption "Wi-Fi support";
        powersave = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable NetworkManager Wi-Fi powersave.";
        };
      };
      wireNames.enable = lib.mkEnableOption "wireX names for physical Ethernet interfaces";
    };

    desktop = {
      enable = lib.mkEnableOption "desktop session";
      environment = lib.mkOption {
        type = lib.types.enum [
          "none"
          "hyprland"
          "river"
        ];
        default = "hyprland";
        description = "Wayland compositor to use for this host.";
      };
      flatpak.enable = lib.mkEnableOption "Flatpak";
      audio = {
        enable = lib.mkEnableOption "PipeWire audio";
        jack.enable = lib.mkEnableOption "PipeWire JACK compatibility";
      };
      apps = {
        browsers.enable = lib.mkEnableOption "browser applications";
        development.enable = lib.mkEnableOption "development applications";
        media.enable = lib.mkEnableOption "media applications";
      };
    };

    system = {
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
      virtualisation.enable = lib.mkEnableOption "libvirt and QEMU virtualisation";
      uinput.enable = lib.mkEnableOption "uinput support";
      ssh.enable = lib.mkEnableOption "OpenSSH server";
      tlp.enable = lib.mkEnableOption "TLP power management";
      laptopPower.enable = lib.mkEnableOption "laptop lid and power button policy";
      yubikey.enable = lib.mkEnableOption "YubiKey, smartcard, FIDO2, GPG, SSH, and age tooling";
      hardwareDev.enable = lib.mkEnableOption "hardware development device access and tooling";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !(cfg.system.cpuVendor == "arm" && cfg.system.architecture == "x86_64");
          message = "ARM CPU vendor cannot be used with x86_64 architecture.";
        }
        {
          assertion = !((cfg.system.cpuVendor == "intel" || cfg.system.cpuVendor == "amd") && cfg.system.architecture != "x86_64");
          message = "Intel/AMD microcode hosts must use x86_64 architecture in this config.";
        }
        {
          assertion =
            cfg.system.architecture == "unknown"
            || cfg.system.architecture == platformArchitecture;
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

    (lib.mkIf cfg.network.networkmanager.enable {
      networking.networkmanager.enable = true;
    })

    (lib.mkIf cfg.network.wifi.enable {
      networking.networkmanager.wifi.backend = "iwd";
      networking.networkmanager.wifi.powersave = cfg.network.wifi.powersave;
    })

    (lib.mkIf cfg.network.wireNames.enable {
      systemd.network.links."10-wire" = {
        matchConfig.Type = "ether";
        linkConfig.NamePolicy = "path";
        linkConfig.Name = "wire";
      };
    })

    (lib.mkIf cfg.network.bluetooth.enable {
      hardware.bluetooth.enable = true;
      services.blueman.enable = true;
    })

    (lib.mkIf cfg.system.ssh.enable {
      services.openssh.enable = true;
    })

    (lib.mkIf cfg.system.uinput.enable {
      hardware.uinput.enable = true;
    })

    (lib.mkIf cfg.system.nvidia.enable {
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
    })

    (lib.mkIf cfg.system.firmware.enable {
      services.fwupd.enable = true;
    })

    (lib.mkIf cfg.system.virtualisation.enable {
      virtualisation.libvirtd.enable = true;
      programs.virt-manager.enable = true;
    })

    (lib.mkIf cfg.system.tlp.enable {
      services.tlp.enable = true;
      services.power-profiles-daemon.enable = false;
    })

    (lib.mkIf cfg.system.laptopPower.enable {
      services.logind.settings.Login = {
        HandleLidSwitch = "suspend";
        HandleLidSwitchExternalPower = "suspend";
        HandleLidSwitchDocked = "ignore";
        HandlePowerKey = "hibernate";
      };
    })

    (lib.mkIf cfg.system.yubikey.enable {
      services.pcscd.enable = true;

      programs.gnupg.agent = {
        enable = true;
        enableSSHSupport = true;
        pinentryPackage = pkgs.pinentry-curses;
      };

      environment.systemPackages = with pkgs; [
        age
        age-plugin-yubikey
        gnupg
        libfido2
        opensc
        pam_u2f
        yubico-piv-tool
        yubikey-manager
        yubikey-personalization
        yubikey-touch-detector
      ];
    })

    (lib.mkIf cfg.system.hardwareDev.enable {
      hardware.keyboard.qmk.enable = true;

      services.udev.packages = with pkgs; [
        dfu-util
        openocd
        probe-rs-tools
        stlink
        usb-blaster-udev-rules
        zsa-udev-rules
      ];

      services.udev.extraRules = ''
        KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"

        ACTION=="add", SUBSYSTEM=="backlight", RUN+="${pkgs.coreutils}/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/backlight/%k/brightness"
        ACTION=="add", SUBSYSTEM=="leds", RUN+="${pkgs.coreutils}/bin/chgrp video /sys/class/leds/%k/brightness", RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/leds/%k/brightness"

        KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0660", TAG+="uaccess"
        KERNEL=="hidraw*", KERNELS=="*054C:0CE6*", MODE="0660", TAG+="uaccess"
        KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0df2", MODE="0660", TAG+="uaccess"
        KERNEL=="hidraw*", KERNELS=="*054C:0DF2*", MODE="0660", TAG+="uaccess"
        KERNEL=="event*", ATTRS{name}=="Wireless Controller", MODE="0660", TAG+="uaccess", SYMLINK+="input/event-ps4"
        KERNEL=="event*", ATTRS{name}=="Wireless Controller Motion Sensors", MODE="0660", TAG+="uaccess", SYMLINK+="input/event-ps4-ms"
        KERNEL=="event*", ATTRS{name}=="Wireless Controller Touchpad", MODE="0660", TAG+="uaccess", SYMLINK+="input/event-ps4-tp"
        KERNEL=="event*", ATTRS{name}=="Sony Interactive Entertainment Wireless Controller", MODE="0660", TAG+="uaccess", SYMLINK+="input/event-ps5"
        KERNEL=="event*", ATTRS{name}=="Sony Interactive Entertainment Wireless Controller Motion Sensors", MODE="0660", TAG+="uaccess", SYMLINK+="input/event-ps5-ms"
        KERNEL=="event*", ATTRS{name}=="Sony Interactive Entertainment Wireless Controller Touchpad", MODE="0660", TAG+="uaccess", SYMLINK+="input/event-ps5-tp"
        KERNEL=="event*", ATTRS{name}=="Xbox Wireless Controller", MODE="0660", TAG+="uaccess", SYMLINK+="input/event-xbox"
        SUBSYSTEM=="input", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="c21f", KERNEL=="event*", MODE="0660", TAG+="uaccess", SYMLINK+="input/event-logi"

        SUBSYSTEM=="usb", ATTRS{idVendor}=="04d8", ATTR{idProduct}=="00dd", TAG+="uaccess"
        SUBSYSTEM=="usb", ATTRS{idVendor}=="534d", ATTRS{idProduct}=="2109", TAG+="uaccess"
        SUBSYSTEM=="usb", ATTR{idVendor}=="1a40", ATTR{idProduct}=="0101", SYMLINK+="openterface", TAG+="uaccess"
      '';

      environment.systemPackages = with pkgs; [
        avrdude
        dfu-util
        openocd
        probe-rs-tools
        qmk
        stlink
      ];
    })

    (lib.mkIf cfg.desktop.audio.enable {
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        jack.enable = cfg.desktop.audio.jack.enable;
      };
      security.rtkit.enable = true;
    })

    (lib.mkIf cfg.desktop.flatpak.enable {
      services.flatpak.enable = true;
      xdg.portal.enable = true;
      xdg.portal.config.common.default = "*";
    })

    (lib.mkIf (cfg.desktop.flatpak.enable && cfg.desktop.environment == "hyprland") {
      xdg.portal.extraPortals = with pkgs; [
        xdg-desktop-portal-hyprland
        xdg-desktop-portal-gtk
      ];
    })

    (lib.mkIf (cfg.desktop.enable && cfg.desktop.environment == "hyprland") {
      programs.hyprland.enable = true;
      systemd.user.services.hyprpolkitagent = {
        description = "Hyprland polkit authentication agent";
        wantedBy = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
          Restart = "on-failure";
        };
      };
      environment.sessionVariables = {
        XDG_CURRENT_DESKTOP = "Hyprland";
        XDG_SESSION_DESKTOP = "Hyprland";
        QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
      };
    })

    (lib.mkIf cfg.desktop.enable {
      security.polkit.enable = true;
      programs.dconf.enable = true;
      services.gnome.gnome-keyring.enable = true;
      xdg.mime.enable = true;

      environment.sessionVariables = {
        GTK_USE_PORTAL = "1";
        XDG_SESSION_TYPE = "wayland";
        QT_AUTO_SCREEN_SCALE_FACTOR = "1";
        QT_QPA_PLATFORM = "wayland";
        HEXE_UNRESTRICTED_CONFIG = "1";
      };
    })
  ];
}
