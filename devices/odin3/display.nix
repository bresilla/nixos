{ ... }:
{
  # The 1080x1920 panel is mounted portrait (Armada: orientation "right");
  # turn it to landscape and keep touch on the same output and rotation.
  programs.morf.uiScale = 1.5;
  programs.morf.hyprland.extraConfig = ''
    hl.monitor({ output = "DSI-1", mode = "preferred", position = "auto", transform = 3 })
    hl.config({ input = { touchdevice = { output = "DSI-1", transform = 3 } } })
  '';
}
