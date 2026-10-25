{ ... }:
{
  # Hyprland handles panel rotation and advertises its actual dimensions to
  # fullscreen Steam and streaming clients, without another virtual display.
  bresilla.programs.steamArm64.session = {
    backend = "hyprland";
    hyprlandExtraConfig = ''
      hl.monitor({ output = "DSI-1", mode = "preferred", position = "auto", scale = 1, transform = 3 })
      hl.config({ input = { touchdevice = { output = "DSI-1", transform = 3 } } })
    '';
    uiScale = "1.5";
  };
}
