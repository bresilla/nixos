{ ... }:
let
  # The 1080x1920 panel is mounted portrait (Armada: orientation "right");
  # turn it to landscape and keep touch on the same output and rotation.
  landscape = ''
    hl.monitor({ output = "DSI-1", mode = "preferred", position = "auto", transform = 3 })
    hl.config({ input = { touchdevice = { output = "DSI-1", transform = 3 } } })
  '';
in
{
  programs.morf.uiScale = 1.5;
  # The greeter runs its own Hyprland configuration.
  programs.morf.hyprland.extraConfig = landscape;
  programs.morf.greeter.extraConfig = landscape;
  # Steam sizes its UI from the internal resolution; render it at the panel's own.
  bresilla.programs.steamArm64.session.gamescopeArgs = [
    "--force-orientation" "right"
    "-w" "1920" "-h" "1080"
  ];
  # Steam treats the EDID-less panel as an external screen and picks 2.8.
  bresilla.programs.steamArm64.session.uiScale = "1.76";
}
