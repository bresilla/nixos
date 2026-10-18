{
  config,
  lib,
  pkgs,
  ...
}:
let
  # FP6's sensor firmware creates and renames registry files. Upstream 0.4.0
  # cannot serve those writes; pin the implementation tested on this phone.
  hexagonrpc = pkgs.hexagonrpc.overrideAttrs (_: {
    version = "0.4.0-fp6-writable-7f2fc1d";
    src = pkgs.fetchFromGitHub {
      owner = "FadyAckad";
      repo = "hexagonrpc";
      rev = "7f2fc1d5afdd811416a4b1bb5664f2a932f7855f";
      hash = "sha256-MqNmKGyVAHpZcg2q9gPxEGgKgUSGDBJgB8e/Y24V5JA=";
    };
  });
  firmwareSource = pkgs.fetchFromGitHub {
    owner = "FairBlobs";
    repo = "FP6-firmware";
    rev = "e58a5be8fa0fb6bc5a5f2e29cc01c036ccf75710";
    hash = "sha256-CkPtCerCH/7+atDjsLmHRoDDyjCVP6U7u8cCw75iv/E=";
  };
  # These are userspace DSP files, separate from the installed boot firmware.
  sensorFirmware =
    pkgs.runCommand "fp6-sensor-firmware"
      {
        meta.license = lib.licenses.unfree;
      }
      ''
        mkdir -p "$out/dsp"
        cp -r ${firmwareSource}/hexagonfs/{sensors,socinfo} "$out/"
        cp -r ${firmwareSource}/hexagonfs/dsp/adsp "$out/dsp/"
      '';
  sensorProxy = config.hardware.sensor.iio.package;
  state = "/var/lib/fp6-sensors";
  autorotate = pkgs.writeShellApplication {
    name = "fp6-autorotate";
    runtimeInputs = [
      pkgs.coreutils
      sensorProxy
      config.programs.hyprland.package
    ];
    text = builtins.readFile ./scripts/autorotate.sh;
  };
in
{
  hardware.sensor.iio.package = pkgs.iio-sensor-proxy.overrideAttrs (old: {
    version = "${old.version}-fp6-android";
    __intentionallyOverridingVersion = true;
    patches = (old.patches or [ ]) ++ [ ./sensors/iio-android-rotation.patch ];
    postPatch = (old.postPatch or "") + ''
      cp ${./sensors/orientation-filter.h} src/fp6-orientation-filter.h
    '';
    postBuild =
      (old.postBuild or "")
      + lib.optionalString (pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform) ''
        $CC -std=c11 -Wall -Wextra -Werror -O2 \
          -I ../src ${./tests/orientation-filter.c} -lm -o test-fp6-orientation
        ./test-fp6-orientation
      '';
  });

  # Register the native proxy without hardware.sensor.iio.enable: that module
  # adds hid-sensor-hub to the initrd, whereas this phone uses Qualcomm SSC.
  environment.systemPackages = [ sensorProxy ];
  services.dbus.packages = [ sensorProxy ];
  services.udev.packages = [ sensorProxy ];
  systemd.packages = [ sensorProxy ];

  # The upstream rules only opt SSC into light/compass support. The raw FP6
  # readings have +Y upright and -X left-up; IIO expects the opposite signs.
  services.udev.extraRules = ''
    ACTION!="remove", SUBSYSTEM=="misc", KERNEL=="fastrpc-adsp", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel", ENV{ACCEL_MOUNT_MATRIX}="-1,0,0;0,-1,0;0,0,1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="iio-sensor-proxy.service"
  '';

  systemd.services.fp6-sensors = {
    description = "FP6 Snapdragon sensor firmware service";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-trigger.service" ];
    before = [ "iio-sensor-proxy.service" ];
    path = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.libssc
    ];
    preStart = ''
      mkdir -p ${state}/sensors
      ln -sfnT ${sensorFirmware}/dsp ${state}/dsp
      ln -sfnT ${sensorFirmware}/socinfo ${state}/socinfo
      ln -sfnT ${sensorFirmware}/sensors/config ${state}/sensors/config
      ln -sfnT ${sensorFirmware}/sensors/sns_reg.conf ${state}/sensors/sns_reg.conf

      # Seed once, then retain the DSP's registry across rebuilds and boots.
      # Rename only after copying finishes, so an interrupted seed is retried.
      if [ ! -d ${state}/sensors/persist ]; then
        mkdir -p ${state}/sensors/persist.new/registry
        cp -r ${sensorFirmware}/sensors/registry/. ${state}/sensors/persist.new/registry/
        chmod -R u+rwX ${state}/sensors/persist.new
        mv -T ${state}/sensors/persist.new ${state}/sensors/persist
      fi

      # ADSP may enumerate after userspace starts. Timeout/restart handles this
      # without resetting the DSP (which also supplies the phone's audio).
      until [ -c /dev/fastrpc-adsp ]; do sleep 1; done
    '';
    postStart = ''
      # Don't let the proxy probe before the DSP has loaded its registry.
      set -o pipefail
      timeout 30s ssccli --sensor accelerometer --timeout 1 \
        | grep -F 'Accelerometer sensor measurement:' > /dev/null
    '';
    serviceConfig = {
      ExecStart = "${hexagonrpc}/bin/hexagonrpcd -s -d adsp -f /dev/fastrpc-adsp -R ${state}";
      StateDirectory = "fp6-sensors";
      StateDirectoryMode = "0700";
      TimeoutStartSec = 60;
      Restart = "on-failure";
      RestartSec = 5;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };

  systemd.services.iio-sensor-proxy = {
    wantedBy = [ "multi-user.target" ];
    wants = [ "fp6-sensors.service" ];
    after = [ "fp6-sensors.service" ];
    # The proxy exits successfully when it cannot find sensors yet.
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
  };

  systemd.user.services.fp6-autorotate = lib.mkIf config.programs.hyprland.enable {
    description = "Rotate the FP6 display and touchscreen with its orientation";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    unitConfig.ConditionUser = config.bresilla.user.name;
    serviceConfig = {
      ExecStart = "${autorotate}/bin/fp6-autorotate";
      ExecStopPost = "-${autorotate}/bin/fp6-autorotate --reset";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };
}
