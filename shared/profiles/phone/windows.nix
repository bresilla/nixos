{ config, lib, pkgs, ... }:
let
  gestures = pkgs.writeShellApplication {
    name = "phone-window-gestures";
    runtimeInputs = [
      config.programs.hyprland.package
      pkgs.jq
    ];
    text = ''
      [[ $# -eq 1 ]] || exit 2
      scrolling=false
      case "$1" in
        scroll-up|scroll-down) scrolling=true ;;
      esac
      # Touch focuses the app in Hyprland. Never act on a locked session,
      # an empty desktop or a special workspace.
      hyprctl -j locked | jq -e '.locked == false' >/dev/null || exit 0
      window=$(hyprctl -j activewindow) || exit 0
      jq -e '.mapped == true and .hidden != true and .workspace.id > 0
        and (.address | test("^0x[0-9a-fA-F]+$"))' <<< "$window" >/dev/null || exit 0

      # Prek passes the swipe's starting centroid in output-local logical
      # pixels, already rotated. Check it against the app and usable area;
      # a visible keyboard must exclude only itself, not the whole screen.
      [[ -n "''${PREK_START_X:-}" && -n "''${PREK_START_Y:-}" ]] || exit 0
      monitor=$(hyprctl -j monitors | jq -ec --argjson window "$window" '
        .[] | select(.id == $window.monitor and .dpmsStatus != false)') || exit 0
      clients='[]'
      if $scrolling; then
        clients=$(hyprctl -j clients | jq -c --argjson monitor "$monitor" '
          [.[] | select(.mapped == true and .hidden != true and .monitor == $monitor.id
            and (.workspace.id == $monitor.activeWorkspace.id or .pinned == true))]') || exit 0
      fi
      jq -en --argjson window "$window" --argjson monitor "$monitor" \
        --argjson scrolling "$scrolling" --argjson clients "$clients" \
        --argjson x "$PREK_START_X" --argjson y "$PREK_START_Y" '
        def inside($w; $p):
          $p[0] >= $w.at[0] and $p[0] < $w.at[0] + $w.size[0]
          and $p[1] >= $w.at[1] and $p[1] < $w.at[1] + $w.size[1];
        $monitor as $m | $window as $w |
        (if $m.transform % 2 == 1 then [$m.height, $m.width]
          else [$m.width, $m.height] end | map(. / $m.scale)) as $size |
        [$x, $y] as $p |
        if $scrolling then
          # Side strips are outside app content; never steal an app scroll
          # that started inside a window and merely ended near an edge.
          ($p[0] < 24 or $p[0] >= $size[0] - 24)
          and $p[1] >= ([$m.reserved[1], 24] | max)
          and $p[1] < $size[1] - ([$m.reserved[3], 24] | max)
          and all($clients[]; inside(.; [$p[0] + $m.x, $p[1] + $m.y]) | not)
        else
          $p[0] >= $m.reserved[0] and $p[0] < $size[0] - $m.reserved[2]
          and $p[1] >= $m.reserved[1] and $p[1] < $size[1] - $m.reserved[3]
          and inside($w; [$p[0] + $m.x, $p[1] + $m.y])
        end' >/dev/null || exit 0

      case "$1" in
        scroll-up|scroll-down)
          # Pan the viewport by half its usable height, clamped to the tiled
          # windows. This changes neither their order nor their workspace.
          gaps=$(hyprctl -j getoption general:gaps_out | jq -c '
            (.css // .custom) | split(" ") | map(select(length > 0) | tonumber)') || exit 0
          border=$(hyprctl -j getoption general:border_size | jq -er '.int') || exit 0
          amount=$(jq -nr --argjson clients "$clients" --argjson monitor "$monitor" \
            --argjson gaps "$gaps" --argjson border "$border" --arg action "$1" '
            $monitor as $m |
            (if $m.transform % 2 == 1 then $m.width else $m.height end) / $m.scale as $height |
            ($height - $m.reserved[1] - $m.reserved[3]) / 2 as $step |
            $m.y + $m.reserved[1] + $gaps[0] + $border as $top |
            $m.y + $height - $m.reserved[3] - $gaps[2] - $border as $bottom |
            [$clients[] | select(.floating == false)] as $windows |
            if ($windows | length) < 2 then 0 else
              (if $action == "scroll-up" then ([$windows[] | .at[1] + .size[1]] | max) - $bottom
                else $top - ([$windows[] | .at[1]] | min) end) as $remaining |
              ([$step, ([$remaining, 0] | max)] | min | round)
              * (if $action == "scroll-up" then -1 else 1 end)
            end')
          (( amount != 0 )) || exit 0
          hyprctl dispatch "hl.dsp.layout(\"move $amount\")"
          ;;
        close)
          address=$(jq -r '.address' <<< "$window")
          hyprctl dispatch "hl.dsp.window.close({window=\"address:$address\"})"
          ;;
        up|down)
          jq -e '.floating == false' <<< "$window" >/dev/null || exit 0
          # swapcol uses tape order even when the tape scrolls vertically.
          direction=l
          [[ "$1" != down ]] || direction=r
          hyprctl dispatch "hl.dsp.layout(\"swapcol $direction\")"
          ;;
        left|right)
          workspace=$(jq -r '.workspace.id' <<< "$window")
          delta=1
          [[ "$1" != left ]] || delta=-1
          target=$((workspace + delta))
          (( target > 0 )) || exit 0
          address=$(jq -r '.address' <<< "$window")
          hyprctl dispatch "hl.dsp.window.move({window=\"address:$address\",workspace=\"$target\",follow=true})"
          ;;
        *) exit 2 ;;
      esac
    '';
  };
in
{
  config = lib.mkIf config.programs.hyprland.enable {
    # This existing session hook appends Hyprland settings after the dotfiles.
    programs.eva.hyprland.extraConfig = lib.mkAfter ''
      hl.config({
        general = { layout = "scrolling", gaps_in = 0, gaps_out = 0, border_size = 0 },
        animations = { enabled = false },
        scrolling = {
          direction = "down",
          column_width = 0.5,
          fullscreen_on_one_column = true,
          wrap_swapcol = false,
        },
      })
    '';

    environment.systemPackages = [ gestures ];
    # The gestures are the user's shortcuts in configs/assets/prek/phone.lua.
    bresilla.programs.prek = {
      enable = true;
      shortcuts = "phone.lua";
    };
  };
}
