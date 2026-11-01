{ freerdp, libva }:

# nixpkgs builds FreeRDP without VA-API; decode RDP's H.264 on the GPU instead.
# FREERDP_VAAPI_DEVICE selects the render node, defaulting to renderD128.
# OpenH264 is tried before FFmpeg, so it is disabled; FFmpeg falls back to software.
freerdp.overrideAttrs (old: {
  # Bitwig appends data after writing its project. Handle both RDP's append
  # marker and the INT64_MAX marker observed from Windows' redirector.
  patches = (old.patches or [ ]) ++ [ ./freerdp-append-offset.patch ];

  buildInputs = old.buildInputs ++ [ libva ];
  cmakeFlags = old.cmakeFlags ++ [
    "-DWITH_VAAPI=ON"
    "-DWITH_OPENH264=OFF"
  ];
})
