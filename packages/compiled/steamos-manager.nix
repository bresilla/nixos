{
  lib,
  rustPlatform,
  fetchFromGitLab,
  fetchFromGitHub,
  pkg-config,
  wrapGAppsNoGuiHook,
  glib,
  gsettings-desktop-schemas,
  speechd-minimal,
  udev,
  coreutils,
  dmidecode,
  iw,
  trace-cmd,
}:

# SteamOS's system service, which Steam's gaming mode needs for its power menu
# and system settings. Built as Armada OS ships it for Qualcomm handhelds: its
# commit, patches (aarch64 device matching among them) and configs.
let
  armada = fetchFromGitHub {
    owner = "armada-os";
    repo = "armada";
    rev = "2fdf06ebba892e2874f874d6202250d63433bf4b";
    sparseCheckout = [ "packages/steamos-manager" ];
    hash = "sha256-vC1ESugi9KWrblB1Ut4odb3NPO2p6AgIMHItsaC379Q=";
  };
  armadaDir = "${armada}/packages/steamos-manager";
in
rustPlatform.buildRustPackage {
  pname = "steamos-manager";
  version = "26.4.1-unstable-2026-09-17";

  src = fetchFromGitLab {
    domain = "gitlab.steamos.cloud";
    owner = "holo";
    repo = "steamos-manager";
    rev = "8e2883d0d7e2fc3994e822ca9853c03561ca6eec";
    hash = "sha256-c3I6cfdJQjXv/1UqKMRgWOtMfCdfHfLeA9uHhs4WYR4=";
  };
  cargoHash = "sha256-+cbBH4Tm/CvYaaP+o6jvlQnbCUM0VToWSX0AIlW/pfs=";

  patches = map (name: "${armadaDir}/patches/${name}") [
    "0001-Initial-support-for-Steam-Frame.patch"
    "0002-Factor-out-platform-profiles-into-its-own-manager.patch"
    "0003-Add-a-custom-platform-profile-mechanism.patch"
    "0004-Explicitly-track-state-in-devfreq-gpu-driver.patch"
    "0005-Add-instructions-to-resolve-common-build-issues.patch"
    "0006-Add-gpufreq_limit-to-custom-profiles.patch"
    "0007-Fix-a-bug-where-UI-could-latch-a-bad-manual-clock-va.patch"
    "0008-Add-GPU-manual-clock-minimum-value.patch"
    "0009-Rename-minfreq-field-to-min_freq-for-consistency.patch"
    "0010-Allow-CpuScaling1-to-be-served-by-a-remote-interface.patch"
    "0011-inputplumber-Only-manage-target-devices-when-configu.patch"
    "0012-wifi-Always-write-wpa_supplicant-as-the-backend.patch"
  ];

  # Its own files move into the store; the tools it calls come from nixpkgs.
  postPatch = ''
    substituteInPlace steamos-manager/src/*.rs steamos-manager/src/*/*.rs steamos-manager-macros/src/lib.rs \
      --replace-quiet /usr/share/steamos-manager "$out/share/steamos-manager" \
      --replace-quiet /usr/bin/dmidecode ${lib.getExe' dmidecode "dmidecode"} \
      --replace-quiet /usr/bin/iw ${lib.getExe iw} \
      --replace-quiet /usr/bin/trace-cmd ${lib.getExe trace-cmd} \
      --replace-quiet /usr/bin/sleep ${coreutils}/bin/sleep \
      --replace-quiet /usr/bin/true ${coreutils}/bin/true
    substituteInPlace data/*/*.service \
      --replace-quiet /usr/lib/steamos-manager "$out/lib/steamos-manager" \
      --replace-quiet /usr/bin/steamosctl "$out/bin/steamosctl"
  '';

  # The tests assume Steam Deck hardware and FHS paths.
  doCheck = false;
  strictDeps = true;
  nativeBuildInputs = [
    glib
    pkg-config
    rustPlatform.bindgenHook
    wrapGAppsNoGuiHook
  ];
  buildInputs = [
    glib
    gsettings-desktop-schemas
    speechd-minimal
    udev
  ];

  # Units as in Jovian-NixOS; device configs as in Armada, upstream's x86 ones dropped.
  postInstall = ''
    mkdir -p $out/lib
    mv $out/bin/steamos-manager $out/lib/steamos-manager
    install -Dm644 -t $out/share/steamos-manager ${armadaDir}/platform.toml
    install -Dm644 -t $out/share/steamos-manager/devices ${armadaDir}/devices/*.toml
    install -Dm644 -t $out/share/dbus-1/system-services data/system/com.steampowered.SteamOSManager1.service
    install -Dm644 -t $out/share/dbus-1/system.d data/system/com.steampowered.SteamOSManager1.conf
    install -Dm644 -t $out/lib/systemd/system data/system/steamos-manager.service
    install -Dm644 -t $out/share/dbus-1/services data/user/com.steampowered.SteamOSManager1.service
    install -Dm644 -t $out/lib/systemd/user \
      data/user/steamos-manager.service data/user/steamos-manager-session-cleanup.service
  '';
  postFixup = "wrapGApp $out/lib/steamos-manager";

  meta = {
    description = "SteamOS system service for Steam's gaming mode, with Armada OS's Qualcomm support";
    homepage = "https://gitlab.steamos.cloud/holo/steamos-manager";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "steamosctl";
  };
}
