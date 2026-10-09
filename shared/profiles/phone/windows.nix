{ config, lib, pkgs, ... }:
let
  gestures = pkgs.writeShellApplication {
    name = "phone-window-gestures";
    runtimeInputs = [
      pkgs.lisgd
      pkgs.libinput
      config.programs.hyprland.package
      pkgs.jq
      pkgs.gawk
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.systemd
    ];
    text = ''
      if [[ $# -gt 0 ]]; then
        fingers=2
        [[ "$1" != close ]] || fingers=3
        # Touch focuses the app in Hyprland. Never act on a locked session,
        # an empty desktop or a special workspace.
        hyprctl -j locked | jq -e '.locked == false' >/dev/null || exit 0
        window=$(hyprctl -j activewindow) || exit 0
        jq -e '.mapped == true and .hidden != true and .workspace.id > 0
          and (.address | test("^0x[0-9a-fA-F]+$"))' <<< "$window" >/dev/null || exit 0

        # lisgd recognizes the swipe but does not pass its coordinates to the
        # command. Check all starting points against the app and usable area;
        # a visible keyboard must exclude only itself, not the whole screen.
        [[ -r "''${PHONE_GESTURE_TOUCHES:-}" ]] || exit 0
        monitor=$(hyprctl -j monitors | jq -ec --argjson window "$window" '
          .[] | select(.id == $window.monitor and .dpmsStatus != false
            and .transform >= 0 and .transform < 4)') || exit 0
        jq -e --argjson window "$window" --argjson monitor "$monitor" --argjson fingers "$fingers" '
          def rotated($t):
            if $t == 1 then [.[1], 100 - .[0]]
            elif $t == 2 then [100 - .[0], 100 - .[1]]
            elif $t == 3 then [100 - .[1], .[0]] else . end;
          $monitor as $m | $window as $w |
          (if $m.transform % 2 == 1 then [$m.height, $m.width]
            else [$m.width, $m.height] end | map(. / $m.scale)) as $size |
          .started <= now and now - .started < 3 and (.points | length) == $fingers
          and all(.points[]; rotated($m.transform) |
            [.[0] * $size[0] / 100, .[1] * $size[1] / 100] as $p |
            $p[0] >= $m.reserved[0] and $p[0] < $size[0] - $m.reserved[2]
            and $p[1] >= $m.reserved[1] and $p[1] < $size[1] - $m.reserved[3]
            and $p[0] + $m.x >= $w.at[0] and $p[0] + $m.x < $w.at[0] + $w.size[0]
            and $p[1] + $m.y >= $w.at[1] and $p[1] + $m.y < $w.at[1] + $w.size[1])
        ' "$PHONE_GESTURE_TOUCHES" >/dev/null || exit 0

        case "$1" in
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
        exit 0
      fi

      umask 077
      state=$(mktemp -d "$XDG_RUNTIME_DIR/phone-window-gestures.XXXXXX")
      export PHONE_GESTURE_TOUCHES="$state/touches"
      mkfifo "$state/events"
      child=
      touch_reader=
      touch_parser=
      previous=
      stop_reader() {
        local pid
        for pid in "$child" "$touch_reader" "$touch_parser"; do
          [[ -n "$pid" ]] || continue
          kill "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
        done
        child="" touch_reader="" touch_parser=""
        rm -f "$PHONE_GESTURE_TOUCHES"
      }
      trap 'stop_reader; rm -rf "$state"' EXIT
      trap 'exit 0' INT TERM

      track_touches() {
        # Read only this touchscreen. Keep starting points in memory/tmpfs;
        # libinput reports them as percentages of the unrotated screen.
        stdbuf -oL libinput debug-events --device "$device" > "$state/events" &
        touch_reader=$!
        gawk -v path="$PHONE_GESTURE_TOUCHES" '
          /TOUCH_CANCEL|DEVICE_REMOVED/ {
            delete down; delete points; count = total = 0
            print "{}" > path; close(path)
          }
          /TOUCH_DOWN/ && match($0, /[[:space:]]([0-9]+) \([0-9]+\)[[:space:]]+([0-9.]+)\/[[:space:]]*([0-9.]+)/, p) {
            if (count == 0) { delete points; total = 0; started = systime() }
            if (!(p[1] in down)) { down[p[1]] = 1; count++ }
            points[++total] = "[" p[2] "," p[3] "]"
            printf "{\"started\":%d,\"points\":[", started > path
            for (i = 1; i <= total; i++) printf "%s%s", (i > 1 ? "," : ""), points[i] > path
            print "]}" > path; close(path)
          }
          /TOUCH_UP/ && match($0, /[[:space:]]([0-9]+) \(/, p) {
            if (p[1] in down) { delete down[p[1]]; count-- }
          }
        ' < "$state/events" &
        touch_parser=$!
      }

      touchscreen() {
        for node in /sys/class/input/event*; do
          [[ $(readlink -f "$node") != */devices/virtual/* ]] || continue
          local candidate="/dev/input/''${node##*/}"
          [[ -r "$candidate" ]] || continue
          if udevadm info --query=property --name="$candidate" | grep -qx ID_INPUT_TOUCHSCREEN=1; then
            printf '%s\n' "$candidate"
            return
          fi
        done
        return 1
      }

      while true; do
        device=$(touchscreen) || device=
        geometry=$(hyprctl -j monitors | jq -er '
          [.[] | select(.disabled != true)]
          | sort_by(.name | startswith("DSI") | not) | .[0]
          | select(. != null and .transform < 4)
          | [.width, .height, .transform, .scale] | @tsv') || geometry=
        identity=$(stat -c '%i:%Y' "$device" 2>/dev/null) || identity=
        current="$device:$identity:$geometry"
        if [[ -z "$device" || -z "$geometry" ]]; then
          stop_reader
          previous=
        elif [[ "$current" != "$previous" ]] \
          || ! kill -0 "''${child:-0}" "''${touch_reader:-0}" "''${touch_parser:-0}" 2>/dev/null; then
          stop_reader
          read -r width height transform scale <<< "$geometry"
          case "$transform" in 1) orientation=3 ;; 3) orientation=1 ;; *) orientation=$transform ;; esac
          edge_scale=$(jq -n --argjson scale "$scale" '$scale * 24 / 50')
          threshold=$(jq -n --argjson scale "$scale" '70 * $scale | round')
          track_touches
          # N excludes screen edges; R performs one action when all fingers lift.
          lisgd -d "$device" -w "$width" -h "$height" -o "$orientation" \
            -s "$edge_scale" -t "$threshold" -r 25 -m 1500 \
            -g "2,DU,N,*,R,$0 up" \
            -g "2,UD,N,*,R,$0 down" \
            -g "2,RL,N,*,R,$0 left" \
            -g "2,LR,N,*,R,$0 right" \
            -g "3,DU,N,*,R,$0 close" \
            -g "3,UD,N,*,R,$0 close" &
          child=$!
          previous=$current
          printf 'Window gestures: %s, %sx%s, scale %s\n' "$device" "$width" "$height" "$scale"
        fi
        sleep 3
      done
    '';
  };
in
{
  config = lib.mkIf config.programs.hyprland.enable {
    # This existing session hook appends Hyprland settings after the dotfiles.
    programs.morf.hyprland.extraConfig = lib.mkAfter ''
      hl.config({
        general = { layout = "scrolling" },
        scrolling = {
          direction = "down",
          column_width = 0.5,
          fullscreen_on_one_column = true,
          wrap_swapcol = false,
        },
      })
    '';

    environment.systemPackages = [ pkgs.lisgd gestures ];
    systemd.user.services.phone-window-gestures = {
      description = "App movement and closing through lisgd";
      wantedBy = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      unitConfig.ConditionUser = config.bresilla.user.name;
      serviceConfig = {
        ExecStart = "${gestures}/bin/phone-window-gestures";
        Restart = "on-failure";
        RestartSec = 3;
      };
    };
  };
}
