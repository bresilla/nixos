{ callaudiod }:

# The Fairphone 6's IMS media process uses the HiFi speakers/microphone. The board
# has no separate ALSA earpiece port, so the speaker alone must be enough.
callaudiod.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    substituteInPlace src/cad-pulse.c \
      --replace-fail 'if (!has_speaker || !has_earpiece)' 'if (!has_speaker)'
  '';
})
