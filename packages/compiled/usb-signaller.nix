{ lib, rustPlatform, fetchFromGitea, pkg-config, udev }:

# usb-moded's D-Bus interface reimplemented for mainline kernels: USB gadget
# modes, role switching and cable detection through typec.
rustPlatform.buildRustPackage (final: {
  pname = "usb-signaller";
  version = "0.4.2";
  src = fetchFromGitea {
    domain = "codeberg.org";
    owner = "DylanVanAssche";
    repo = "usb-signaller";
    rev = "v${final.version}";
    hash = "sha256-c4wI6sHHiCad18t62dD9SEgdmoo0S+BO22wUGytIJ0Q=";
  };
  cargoHash = "sha256-cmsxh7ZjU4z2LvwsnqZNlS5P9aeL05eZrg+mPDR9ShQ=";
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ udev ];
  # These expect existing sysfs paths, absent in the build sandbox.
  checkFlags = [
    "--skip=sysfs::tests::mkdir_path_already_exists"
    "--skip=sysfs::tests::symlink_destination_path_already_exists"
  ];
  # It only takes systemd as the init system when systemctl is under /usr/bin.
  postPatch = ''
    substituteInPlace src/service.rs \
      --replace-fail '"/usr/bin/systemctl"' '"/run/current-system/sw/bin/systemctl"'
  '';
  postInstall = ''
    install -Dm644 com.meego.usb_moded.conf $out/share/dbus-1/system.d/com.meego.usb_moded.conf
    install -Dm644 usb-signaller.service $out/lib/systemd/system/usb-signaller.service
    substituteInPlace $out/lib/systemd/system/usb-signaller.service \
      --replace-fail /usr/bin/usb-signaller $out/bin/usb-signaller
  '';
  meta = {
    description = "usb-moded compatible USB gadget daemon for mainline Linux mobile devices";
    homepage = "https://codeberg.org/DylanVanAssche/usb-signaller";
    license = lib.licenses.gpl3Plus;
    mainProgram = "usb-signaller";
    platforms = lib.platforms.linux;
  };
})
