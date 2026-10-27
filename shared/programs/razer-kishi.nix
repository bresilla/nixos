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
    import time
    from evdev import InputDevice, UInput, ecodes as e, list_devices

    keys = {0x0132: e.${cfg.exitKey}, 0x012B: e.${cfg.screenshotKey}}
    ui = UInput({e.EV_KEY: list(keys.values())}, name="${name}")
    held = set()

    # The screenshot button also sends Android's power key on the Consumer Control
    # device; holding it exclusively keeps logind and the desktop from locking.
    grabbed = []
    for _ in range(10):
        for path in list_devices():
            dev = InputDevice(path)
            if dev.name == "Razer Razer Kishi V3 Consumer Control":
                dev.grab()
                grabbed.append(dev)
        if grabbed:
            break
        time.sleep(0.5)
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
    services.udev.extraRules = ''
      # ATTRS matches must all come from one parent; the IDs and the interface are on two.
      ACTION=="add", SUBSYSTEM=="hidraw", IMPORT{builtin}="usb_id", ENV{ID_USB_VENDOR_ID}=="1532", ENV{ID_USB_MODEL_ID}=="0037", ENV{ID_USB_INTERFACE_NUM}=="02", TAG+="systemd", ENV{SYSTEMD_WANTS}+="kishi-buttons@%k.service"
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
