{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.programs.razerKishi;
  name = "Razer Kishi V3 extra buttons";
  # The two bottom buttons arrive as report 7 on the HID interface 2, with an
  # undefined usage the kernel drops; this turns them into keys on a uinput device.
  buttons = pkgs.writers.writePython3 "kishi-buttons" {
    libraries = [ pkgs.python3Packages.evdev ];
    flakeIgnore = [ "E501" ];
  } ''
    import sys
    from evdev import UInput, ecodes as e

    keys = {0x0132: e.${cfg.exitKey}, 0x012B: e.${cfg.screenshotKey}}
    ui = UInput({e.EV_KEY: list(keys.values())}, name="${name}")
    held = set()
    with open(sys.argv[1], "rb", buffering=0) as raw:
        while report := raw.read(64):
            if report[0] != 7:
                continue
            codes = {report[i] | report[i + 1] << 8 for i in range(1, len(report) - 1, 2)}
            down = {keys[c] for c in codes if c in keys}
            for key in down ^ held:
                ui.write(e.EV_KEY, key, int(key in down))
            ui.syn()
            held = down
  '';
in
{
  options.bresilla.programs.razerKishi = {
    enable = lib.mkEnableOption "the Razer Kishi V3's exit and screenshot buttons as keys";
    exitKey = lib.mkOption {
      type = lib.types.str;
      default = "KEY_BACK";
      description = "The key the exit button sends.";
    };
    screenshotKey = lib.mkOption {
      type = lib.types.str;
      default = "KEY_SYSRQ";
      description = "The key the screenshot button sends.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Its screenshot button also sends Android's power key, which logind would lock on.
    services.udev.extraRules = ''
      SUBSYSTEM=="input", ATTRS{idVendor}=="1532", ATTRS{idProduct}=="0037", TAG-="power-switch"
      ACTION=="add", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1532", ATTRS{idProduct}=="0037", ATTRS{bInterfaceNumber}=="02", TAG+="systemd", ENV{SYSTEMD_WANTS}+="kishi-buttons@%k.service"
      ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="${name}", TAG+="uaccess"
    '' + lib.optionalString config.bresilla.programs.steamArm64.gamepadLaunch.enable ''
      ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="${name}", TAG+="systemd", ENV{SYSTEMD_USER_WANTS}+="steam-gamepad-hold@%k.service"
    '';
    systemd.services."kishi-buttons@" = {
      description = "Razer Kishi V3 exit and screenshot buttons (%I)";
      bindsTo = [ "dev-%i.device" ];
      after = [ "dev-%i.device" ];
      serviceConfig.ExecStart = "${buttons} /dev/%I";
    };
  };
}
