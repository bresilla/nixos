# Fairphone 6

This is the FP6 we boot-tested, not the FP5. It uses the Android bootloader and
a device-specific kernel. A PC live-USB Disko installation is not suitable.

- `default.nix`: device settings and USB/Wi-Fi networking.
- `hardware.nix`: kernel and firmware from `kernel/`, USB gadget and boot-image builder.
- `kernel/`: the pinned kernel and firmware recipe; `config` is the configuration the
  first kernel ran with.
- `storage.nix`: nested 4096-byte-sector GPT inside Android `userdata`, root growth
  and the `FP6-BOOT` filesystem label. This uses systemd-repart, not Disko.
- `touchscreen.nix`: boot recovery for the ESWIN controller after display startup.
- `rotation.nix`: Snapdragon sensors and automatic Hyprland/touch rotation.
- `audio.nix`: AudioReach topology, amplifier firmware and ALSA speaker/microphone routing.
- `modem.nix`: modem services, with SIM initialization in `scripts/`.
- `calls.nix`: native IMS/VoLTE, the Calls dialer and call audio integration.
- `battery-log.nix`: a CSV of battery drain, suspend count and the busiest process every
  five minutes, in `/var/lib/battery-log/battery.csv`.
- `development/`: a flake for explicit kernel builds from `kernel/`, and the tools shell.
- `update-boot.sh`: checked boot-image updates on the installed FP6 (slot A).
- `u-boot.md`: notes on booting through U-Boot and systemd-boot instead.

The shared `#phone` profile supplies applications and accounts. In the repository
checkout on this phone, `machine.nix` selects it:

```nix
{ profile = "phone"; device = "fairphone-fp6"; }
```

Keep `user.nix` on the device. It contains no
plaintext password. SSH uses the account's authorized keys; change its password
interactively with `passwd`.

Morf's NixOS module installs pattern support. Run `sudo morf-pattern setup USER` after
setting the account password. The hidden, confirmed prompt validates adjacent
dots and stores a root-only salted hash on the device. This enrollment is shared
by greetd and the lock screen. Normal updates preserve it; neither the pattern
nor its hash goes into `user.nix` or a built image. The live-USB installer offers
the same step automatically after setting the password on desktop installations.

Morf's executable and Lua library use the named Paneworks cache entries. Its
upstream NixOS module supplies the graphical integration and complete fallback
theme. The desktop profile selects that packaged UI for shell, lock and greet.
`programs.morf.phone.enable` selects native gestures and double-tap or
power-key wake. Scrolling inertia, panel/workspace gestures, the phone scrollbar
and the hidden app list in the phone bar belong to Morf's implementation. This
device sets compositor scale and idle preferences; it carries no Morf patches,
copied source tree or source-build override.

Neither the account password nor the pattern is saved in this repository or
the Nix store. The pattern's salted hash stays under `/var/lib/morf/pattern`
with root-only access. Rebuilding preserves enrollment; after wiping userdata,
enroll again. Only enrolled users are offered a pattern by the greeter.

## Steam gaming session

The greeter's session chip (tap it, or press F2) chooses between Hyprland with
Morf and **Steam Gaming Mode**. The phone profile enables the same ARM64 Steam
client and Proton package as the handheld profile, without automatic login.
Exiting the selected Steam session returns to the greeter. The handheld keeps
its automatic login and direct desktop switching.

`gaming.nix` sets landscape orientation and Steam UI scale for the phone with
its Razer Kishi attached. Steam discovers the display dimensions automatically.
A minimal Hyprland compositor drives the
rotated panel and touch, running only fullscreen Steam. Gamescope's direct DRM
backend did not present frames on this panel, and nesting it introduced a separate
16:9 Steam UI display. The controller is exposed by the kernel's `xpad` driver;
the Odin's InputPlumber configuration is not
needed for this controller. Game compatibility and performance depend on the
game and still need testing on the FP6.

## Updating the installed phone

Run `curl -fsSL https://nix.bresilla.dev | bash` on the phone. Or use its checkout:

```sh
cd /etc/nixos
sudo git pull
sudo ./install.sh
```

Update is automatic. It reuses the account, resolves current software inputs and
applies the system. The kernel and firmware come from the pinned recipe in
`kernel/`, with its own nixpkgs, so software updates never change them. The
recipe cross-compiles on x86_64; the phone sends that build to tron as its
remote builder (`shared/system/builders.nix`) and compiles nothing itself.
The kernel includes the ESWIN touchscreen driver.
The `fp6-touchscreen` service waits until the active Hyprland compositor reports
the phone display powered on, then rebinds this driver once. The boot framebuffer
can report an enabled panel before the compositor starts; resetting at that point
leaves the controller enumerated but producing no touches. This is a
device-specific workaround using the existing module.
The updater repackages and writes the boot image so it starts the new system.
It keeps the previous image in `/var/lib/fp6-boot` for a Fastboot rollback.
A plain `nixos-rebuild switch` alone
does not update the Android boot partition.

Automatic rotation uses `fp6-sensors` to serve the ADSP sensor firmware,
`iio-sensor-proxy` to report orientation, and the `fp6-autorotate` user service
to rotate `DSI-1` and its touchscreen together. The shell listener preserves
the current compositor scale and position. Sensor firmware and the writable
registry implementation of `hexagonrpc` are pinned in `rotation.nix`; this
does not rebuild the kernel. The registry is seeded once into
`/var/lib/fp6-sensors/sensors/persist` and retained across updates.

The FP6 sensor proxy applies the sensor limits from AOSP Android 16's
[AccelSensorJudge](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r4/services/core/java/com/android/server/wm/WindowOrientationListener.java):
200 ms low-pass filtering, a 45-degree hysteresis gap (integer thresholds of
67 degrees to enter landscape and 23 degrees to return), and 40 ms of stable
prediction. Rotation waits 500 ms after acceleration or leaving a flat pose,
and 300 ms after a swing. Tilt limits are -25 to 70 degrees for portrait,
-25 to 65 for landscape, and -25 to 60 upside down; overhead use locks rotation
below -40 degrees until raised past -15. These are AOSP's accelerometer defaults,
not a claim to reproduce Fairphone's proprietary orientation sensor or Android's
touch/app-specific rotation policy. The filter and its build-time regression
tests live in `sensors/` and `tests/`; the Hyprland listener remains a shell script.

Check `systemctl status fp6-sensors iio-sensor-proxy` and
`systemctl --user status fp6-autorotate` for diagnostics. Run
`monitor-sensor --accel` from the phone session to see orientation events.
`systemctl --user stop fp6-autorotate` pauses rotation and restores portrait;
`systemctl --user start fp6-autorotate` resumes it.

The kernel recipe pins the milos speaker branch and adds the WCD9378 microphone
driver and device-tree changes. `audio.nix` supplies the matching AudioReach
topology, AW88261 amplifier firmware and UCM HiFi profile. It sets the UCM path
for PipeWire and WirePlumber without rebuilding their ALSA dependencies.
The capture PCM has two channels, with microphone audio only on the left.
PipeWire exposes that channel as a mono microphone. The UCM profile applies
30 dB of analogue microphone gain and 6 dB of digital gain; the original mixer
levels produced very quiet recordings on the handset.

An older kernel can register an ALSA card while exposing no PCM devices; in that
case PipeWire shows only Dummy Output. Check `/proc/asound/pcm`, `aplay -l`,
`arecord -l` and `wpctl status`. Installing userspace profiles alone cannot add
the missing kernel audio links; that takes a kernel change in `kernel/`.

Calls use the pinned native `imsd` service and its oFono-compatible bridge.
The Calls dialer uses that bridge; ModemManager continues managing the radio
and data bearers. IMS bring-up discovers the carrier's proxy on a separate
`ims` bearer without replacing the default route. The kernel must include
XFRM userspace control and IPv4/IPv6 ESP. The firewall admits IMS signalling
and media on modem mux interfaces only. Optional carrier overrides belong in
`/etc/imsd.env`, outside Git. Carrier registration and two-way call audio still
require on-device verification.

The media process uses the active session's PipeWire speaker and microphone.
The current UCM profile exposes stereo speakers, without a separate earpiece
route; the FP6 callaudiod build accepts this profile. Check `systemctl status
imsd imsd-ofonod imsd.timer` and the Calls XDG autostart unit in
`systemctl --user`. Calls supplies its own autostart entry; do not add a second
daemon service. A timer starts IMS independently of the boot targets, so slow
carrier registration cannot hold up UWSM's graphical login. The IMS package
runs upstream protocol/state-machine tests during its Nix build.

`fingerprint.nix` supplies the native FocalTech FT9391 daemon, standard fprintd
clients, and Morf's separate fingerprint PAM stack. Password login remains
available. The daemon starts through D-Bus when requested; it does not delay
graphical startup. Standby unlocking through logind is disabled so Morf's PAM
conversation decides whether to unlock. Template learning is disabled to match
upstream's tested configuration.

The firmware extractor reads the phone's own signed `focal64` image from its
stock modem partition. Encrypted templates remain on the Android `persist`
partition, while finger-name mappings live in `/var/lib/fingerprintd`. These
templates use hardware anti-rollback counters: copying old files back is not
a valid restore method. Keep the partition and name mappings across upgrades.

Enrollment and deletion require administrator access; ordinary applications
can only verify. Use `sudo fprintd-enroll -f right-thumb bresilla`,
`fprintd-list bresilla`, and `fprintd-verify bresilla` for interactive setup and
testing. Replace the username and finger as needed. Enrollment takes 20 accepted
touches, lifting fully between them. The package tests both the protocol code
and its D-Bus restrictions on enrollment and deletion. Compile it on Tron.

After supplying `user.nix`, build `fp6-userdata` and `fp6-boot`, then use Fastboot to
flash `userdata` and `boot_a`, and erase `dtbo_a`. This replaces phone data and
requires the unlocked bootloader, verified backups and slot A selected. Check the
device identity before any flash. Never run a generic Disko erase on the phone.

## Development and recovery

From the repository root, `nix develop .#fp6` opens the tool environment.
`nix build path:./devices/fairphone-fp6/development#kernel` explicitly compiles a kernel,
cross-compiling on x86_64 or compiling natively on ARM64. Full x86-hosted hardware
and phone image builds also need an ARM64 builder for firmware and userspace.
The development flake is independent of normal application updates.

To change the kernel, edit `kernel/` and commit; the next update sends the build
to tron. If tron is unreachable, the update stops instead of compiling here.

Boot images must contain a complete 96 MiB image with valid AVB metadata; a short
raw Android image can leave a stale footer and return to Fastboot. The builder
adds and verifies that metadata. The boot filesystem label is uppercase
`FP6-BOOT`, matching FAT's actual label.

Recovery archives and the original phone partition backups are private artifacts,
not repository files. The existing archives remain in the original
`../nixos-fp6/.build/recovery` workspace; preserve them separately from the Git repo.
Do not change slots with qbootctl or relock the bootloader during recovery.

The first working image was NixOS 26.05 with the 7.2.0 device kernel. USB SSH,
root growth, `/boot` and the firewall were verified through a reboot. Morf and
touch input have also been tested. Mobile data, calls and cameras still need
hardware testing.
