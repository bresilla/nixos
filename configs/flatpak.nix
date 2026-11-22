{
  # Blender reads the gearbox checkout and runs its compiler on the host.
  home.file.".local/share/flatpak/overrides/org.blender.Blender".text = ''
    [Context]
    filesystems=~/data/code/robolibs/gearbox;

    [Session Bus Policy]
    org.freedesktop.Flatpak=talk
  '';
}
