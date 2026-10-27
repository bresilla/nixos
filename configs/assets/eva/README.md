# eva

A desktop shell, lock screen and greeter for
[morf](https://github.com/paneworks/morf). It is a clean-room
reimplementation of [caelestia-dots/shell](https://github.com/caelestia-dots/shell)'s
look and behaviour, written from watching the original run rather than from
its source, with two visual themes: Material and Tsugumori.

## Install on NixOS

```nix
{
  inputs.eva.url = "github:bresilla/eva";

  outputs = { nixpkgs, eva, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        eva.nixosModules.default
        {
          programs.eva = {
            enable = true;
            user = "you";
            lulePackage = lule; # the colour tool behind the wallpaper
          };
        }
      ];
    };
  };
}
```

The module runs the shell as the `morf` user service, the greeter under
greetd and the lock screen from Hyprland's idle daemon. It also handles the UI
scale shared with the greeter, the wallpaper bridge, PAM, and, optionally,
phone gestures and pattern unlock. Its options live under `programs.eva`:
`uiScale`, `idle.*`, `phone.*`, `pattern.enable`, `hyprland.extraConfig`,
`greeter.*`, `wallpaperLogo` and `usePackagedShell`.

On a phone, `phone.enable` adds continuous touch gestures, a hidden pointer and
deliberate double-tap or power-button wake. `phone.idleTimeout = 0` disables
automatic locking in the user session; the phone greeter still blanks after
one minute. A blanked lock screen stops its fingerprint reader, and waking
the display starts it again. Panels follow the finger and carry release
speed into their settling animation. An inward pull from the left edge opens Apps and from the
right edge opens Web. A short, fast fling works too, while cancelled pulls and
authentication prompts suppress launcher gestures. Bottom gestures remain
available for workspaces and the keyboard. Lists use Android's
[OverScroller spline physics](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/widget/OverScroller.java):
faster releases coast farther, touching stops the coast, and slow frames do not
change the travel distance. `phone.gestureDriver = "lisgd"` selects the
completed-swipe fallback; the default is `"native"`.

eva pins the morf release it is written against in `flake.nix`, and the engine
comes prebuilt from the paneworks binary cache. The engine and its Lua library
always come from that same release. A shell in `~/.config/morf/default` is used
in place of the packaged one, unless `programs.eva.usePackagedShell` is set.

## Which morf

`morf.lua` says which engine eva is written for (`morf = ">=0.6.0"`) and the
release line it was last tested on (`tested = "0.6"`). An engine that reads it
(morf 0.4 and later) refuses eva when it is too old, with a plain
`eva 0.1.0 needs morf >=0.4.0; this is morf 0.3.0`, and `morf check` fails, so
the NixOS launcher falls back. An engine past the tested line runs eva and
logs a warning. A theme's manifest can ask for more than eva does
(`morf = ">=0.4"` beside its `api`): on an engine that cannot meet it, eva
starts in Material with a notification saying why, and the switcher refuses
the theme with the same reason.

## Run and develop

```sh
nix develop                          # morf, at the pinned release, on PATH
morf shell/init.lua                  # the shell
morf lock/init.lua -- window preview # the lock screen, without authenticating
make test                            # every spec (tools/test.sh)
make check                           # the shell, lock and greeter load cleanly
```

## Using it

The optional typed Prek controller receiver is documented in
[Prek controls](https://github.com/paneworks/morf/blob/main/docs/PREK_CONTROLS.md); broker binding and recognizer
handoff remain pending.
The top, bottom, left and right panel triggers wait for a 600 ms hover
before opening, including at the outermost pixel. Leaving early cancels
the pending opening. IPC also opens them:

```sh
morf ipc call capture toggle
morf ipc call bottom open
morf ipc call assistant open
morf ipc call tasks open
morf ipc call calendar open
morf ipc call close
```

The bottom edge opens a large workspace with **Assistant** and **Drop**
tabs. Material's maximum size is 1696 × 751, with the same proportional
reduction on smaller screens (20% narrower and 40% shorter than the previous
panel). Tsugumori keeps that desktop footprint and uses the available width
on compact screens, with vertically scrollable pages.
Assistant awaits a provider; Drop is a placeholder for the future
[termworks/drop](https://github.com/termworks/drop) messaging and file-sharing
integration. Open it directly with `morf ipc call bottom open drop`.
Click outside the workspace to close it from either tab. When opened by
hovering the bottom edge, it also closes after the pointer leaves it.
Add future pages in `shell/bottom_model.lua` and register their builders in
each visual theme. Assistant, Drop and the workspace container have separate
Material and Tsugumori layouts.

**Lule** lives in the top dashboard, in a 992 × 588 panel. The wallpaper
gets 60% of the top row, with a narrower color pane beside it and a control
strip below; all color swatches and Apply stay visible. **Wallpaper folder**
shows the collection used by Images, Shuffle, the arrows, and Random & apply.
Edit that field and press **Use folder** (or Enter) to save a different folder;
`~/` paths work. This remembers `lule.folder` in the shell's `eva.json`
settings across restarts and monitors. Invalid folders leave the collection
unchanged. Initially it uses `LULE_W`, then the current wallpaper's folder.
This is the panel's collection setting; standalone Lule still uses its own
`lule.wallpaper` config / `LULE_W` environment setting.
Use Images, Shuffle or the arrows to preview an image.
The folder is rescanned when opening the tab or Images, shuffling, using the
arrows, or choosing Random & apply, so added and removed images are picked up
automatically. Use folder is only needed to change the collection's directory.
Choose dark/light and a palette method, then press
**Apply wallpaper & colors**. **Random & apply** chooses another image and
applies it immediately using the selected appearance and palette method.
Images and Shuffle remain preview actions.
The swatches show the currently applied ANSI palette and special colors;
click a swatch to copy its hex value. Open directly with `morf ipc call lule open`
or click the top dashboard’s Lule tab. With no arguments, `morf ipc call lule`
still reports the terminal/accent diagnostics.

The tab runs `lule create --image=… --theme=… --palette=… -- set` through
`lib.integrations.lule.generate`, preserving Lule's config, templates and desktop hooks.
Current Lule uses `~/.config/lule/init.lua` (or `LULE_C`); a separate legacy
`lule_colors` script is not run a second time. The bundled tab icon is Lule's
original SVG geometry: outlined when inactive, filled with the accent when
selected. Its license is in `shell/assets/`.

Previews resize on an image worker only while the Lule page is visible.
They overwrite one small scratch JPEG per output and clear on closing;
opening the shell does not decode an entire wallpaper collection.

Quick settings groups Keep Awake, Ring Mode and Do Not Disturb under **Focus**.
Opening Focus leaves all three settings independent. **Tunnel** includes Tor's
Start/Stop control, bootstrap progress and SOCKS proxy address alongside VPNs;
its overview status includes Tor when running. The old `settings tor` IPC
shortcut opens Tunnel.

PrintScreen, the **Screenshot / Record** button in quick settings, or
`morf ipc call capture open` opens the compact bottom capture panel. Choose
region, window or screen, an optional delay, then Screenshot or Record.
The panel closes before capture. Recording uses its existing commands.
Screenshots freeze the desktop at its normal size: drag a region, click a
window, or press `S` (or Enter) for the current monitor. The screen target
already selects that monitor.

After selection, a compact floating editing menu appears beside the capture,
with Copy, Save, undo/redo, Draw and More. Draw expands the tool palette;
More includes Select again, Upload, Settings and Cancel. The toolbar can be
dragged. Handles appear after selection for resizing. Window snapping uses
Hyprland or Sway geometry, or the floating window geometry available from Niri.

The editor supplies select, rectangle, ellipse, line, arrow, pen, highlight,
text, numbered steps, blur, pixelate and zoom. Select moves annotations;
Delete removes the selected one. `F` switches rectangle/ellipse fill, the
wheel changes stroke/text size while drawing, and each tool remembers its
colour, width and fill across launches. `Ctrl+Z`/`Ctrl+Shift+Z` undo/redo;
`Ctrl+C`, `Ctrl+S` and `Ctrl+U` copy, save and request upload. Escape or
Cancel dismisses immediately; clicking outside the selected region also
closes the editor. The tool palette wraps on small screens. Both themes use their own controls and title animations.

Settings expose blur strength, pixel size, zoom factor, a custom hex colour,
save folder, an internal save/folder chooser, copy-on-save, save-on-copy,
pointer inclusion and key rebinding. Preferences live in `shell.json`;
defaults belong to `shell/config.lua`. Hyprland shortcut changes apply
immediately and are restored after reload. Set `capture.keybind_file` to a
dedicated include file if you want to write the generated binding there too.
The default compositor binding remains:

```lua
bind_exec("Print", "/usr/bin/morf ipc call capture open")
```

Upload requires a separate confirmation. It sends only the rendered image,
with metadata removed by re-encoding, to `capture.upload_endpoint` (default
Litterbox); the default link is public and expires after 72 hours. The URL
is copied to the clipboard. Nothing is uploaded automatically.

Acquisition uses Morf's native Wayland screencopy; KDE uses Spectacle.
Image composition/effects run on workers without ImageMagick. `wl-copy`
keeps the image clipboard alive after the shell exits; uploads use `curl`.
Live drawing uses native Path geometry; committed previews keep a decoded
monitor image and publish pixels directly, without a PNG round trip for each
edit. Lua owns tool selection, undo history and themed controls; Rust builds
and rasterizes the annotation geometry. Save/Copy still encode an export.
Temporary captures/previews are cleaned when editing ends, with bounded
undo and preview caches. There is no screenshot history or gallery.
`morf ipc call capture-editor cancel` closes editing across outputs;
`morf ipc call screenshot screen quick` retains the old command-based
capture. Set `capture.editor = false` to use that path by default.

Recording still uses the configured commands; custom recorders must stay in
the foreground (use `exec` in a wrapper) so Morf can track and stop them.
Quick capture/recording commands may use `grim`, `slurp`, `hyprctl`, `jq`
and `gpu-screen-recorder`. Reopen the popup to stop the recorder it started
or cancel a pending countdown.

Run `morf shell`, `morf lock`, or `morf greet`. Preview without authenticating
with `morf lock -- window preview` or `morf greet -- preview`.
See [system installation](https://github.com/paneworks/morf/blob/main/docs/INSTALL.md) for the full workflow.

The left panel has **Tasks** and **Calendar** tabs. Tasks uses the installed
`task` executable and the user's normal Taskwarrior configuration, including
`TASKRC` and `TASKDATA`. Its client is eva's `lib.integrations.taskwarrior`.
No second task database or sync service is created. Tasks refresh when the
panel opens, every ten seconds while open, and after a successful change.

Click a task to edit its description, project, priority, scheduled date and
time, deadline, waiting date, tags, recurrence, recurrence end, or dependencies.
Dates accept Taskwarrior expressions such as `tomorrow`, or an ISO date/time
such as `2026-10-01T09:00`. A repeating task needs a due date. Editing one
occurrence does not propagate changes to its siblings. The editor also
offers start/stop, completion, and deletion with a second click to confirm.

Calendar shows a month and tasks scheduled or due on the selected day, in
local time. “Plan a task” preselects that day. Work-mail meetings are not
connected yet; the calendar explicitly shows that state.

Performance and battery graphs collect the latest 60 samples while their
tabs are closed, except while a phone display is blanked. Old samples are
overwritten in memory; restarting the shell resets them. No history files
are written.
Reloading the configuration also starts a new history. CPU history spans
two minutes; memory and battery span three minutes. After a restart or
reload, the graphs fill from the right as samples arrive.

`morf ipc call dashboard-history` reports sampling counters and errors without
waking idle sources. Pass an output name (for example `dashboard-history DP-6`)
to inspect that monitor. The counters should increase with the drawer closed.

## Visual themes (in progress)

The shell, lock and greeter select a visual package with
`EVA_STYLE=material` or `EVA_STYLE=tsugumori`. Without that override,
selection comes from `theme` in `$XDG_CONFIG_HOME/morf/eva/appearance.json`
(or the file named by `EVA_APPEARANCE`); Material is the default.
Changing the selection currently requires restarting the preview. Wallpaper
and Lule colors remain independent of that selection.

Both themes use the same content builders in `themes/layouts/`: sections,
control order, navigation and information grouping stay the same. Useful
section titles are shared additions too. Tsugumori supplies typography,
framed controls, subtle wallpaper-accent borders, title decoding, hover
feedback and covered transitions. Its approved edge pills remain a visual
override. Every tab has its icon at the right end, including Lule's custom SVG.

Shell services and authentication remain outside the visual components.
Preview mode disables task changes and real authentication actions. The
conversion and broad verification are still in progress; see
[THEMING.md](THEMING.md). Develop and review in the isolated sandbox before
installing.

## Checks

```sh
make test                                   # every spec, in parallel shards
sh tools/test.sh tests/panels_spec.lua      # some of them
MORF=path/to/morf sh tools/test.sh          # against another engine build
python3 -m unittest discover -s nix/tests   # the NixOS module's screen and wallpaper helpers
```

`tools/films/` records frame-by-frame films of the drawers and the motion,
and `tools/keyring_test_ui.py` runs the keyring dialog against a real GCR
prompt; neither runs in CI.

The specs stub external commands and never change the user's tasks or
record the desktop. eva's own library, `lib/` (Lule, Taskwarrior, the
modem, settings, capture and the rest), is tested by `tests/lib_*_spec.lua`.

Keyring prompts use morf when the optional `morf-keyring` helper is installed
on PATH. See [the bridge build and test instructions](https://github.com/paneworks/morf/blob/main/tools/keyring/README.md).
The bridge keeps GNOME Keyring as the secret store and displays unlock,
new-password and confirmation dialogs using the current theme. It starts on
the primary output, waits for existing GNOME prompts to finish, and leaves
GNOME's original prompter available when the shell is stopped. Inspect its
status with `morf ipc call keyring`.

The **Shell theme** controls at the bottom of Lule switch between Material and
Tsugumori without restarting the process. Open drawers use a feathered wipe while
the frame stays visible and its corners and seams morph between styles. Restored
cards start settled so their entrance animations do not compete with the reveal.
Font-only changes use a dissolve. The selected theme is saved in
`$XDG_CONFIG_HOME/morf/eva/appearance.json` (`EVA_APPEARANCE` overrides
that path); `EVA_STYLE` remains a startup override for previews.

The switch retains open drawers, selected tabs, Taskwarrior editor drafts,
Lule selections, notification history, and bounded performance/battery samples
in memory. These snapshots are released after the switch and never written to
disk. Finish an active authentication prompt, capture, task operation, or Lule
apply before switching. IPC also supports `morf ipc call appearance material`
and `morf ipc call appearance tsugumori`; calling `appearance` alone reports the
current theme and transition status.

The adjacent **Font** picker searches installed font families and previews each
face. Choose **Theme default** to restore Material or Tsugumori's own typeface.
The shell font is saved as `font` in the same appearance file, stays selected
when changing themes, and uses the same smooth, state-preserving transition.
Icons retain their symbol font. Installed families are scanned with `fc-list`
when opening the picker, then cached until the next shell reload. IPC accepts
`morf ipc call appearance 'font:Goku'`; `font:` resets the font choice.

Lock controls follow the pointer's output. Each output uses its own logical
dimensions, including space for pattern input and the on-screen keyboard;
other outputs show the clock and background. The lock has one private password
draft across all outputs. The greeter stays on Cage's main display with one
private draft and one authentication conversation.
Both views rebuild their presentation after a resize or rotation while retaining
controller state. Small outputs keep readable controls and scroll the sheet;
pattern input fits the visible area. Replacing a keyboard cancels held keys and
pending repeats. Short greeter outputs reserve a footer for power controls.
The lock's live monitor list drops disconnected displays, so its controls move
to a remaining output and recover when a display reconnects.

Connecting headphones shows a centered status badge for 3.2 seconds on the active
output. Earbuds get a separate icon when the name or form-factor metadata identifies
them; generic analog jacks use headphones because they cannot distinguish the
physical accessory. One `pactl subscribe` watcher reads audio-route changes,
including wired jack availability, without idle polling. Native audio metadata is
the fallback when PulseAudio compatibility is unavailable. Devices present at
startup, volume changes and brief Bluetooth profile handoffs stay quiet.
Preview with `morf ipc call headphones-demo` or
`morf ipc call headphones-demo earbuds`.

Under Cage the greeter uses one login window on Cage's main display. The view
uses its configured fullscreen window size and never follows the pointer or
rebuilds in response to monitor metadata. Locking remains independent.

## Sound and nested settings

Sound opens **Equalizer**, which opens a deeper **Audiogram** editor. Back
returns to the parent page. Other settings can use the same hierarchy:
add a descriptor with `key`, `name`, and `parent` to `settings_model.DETAILS`
and a builder in `utilities.lua`. Breadcrumbs and presentation scopes follow
the registry. `morf ipc call settings sound/equalizer` opens the EQ directly.

The EQ provides eight tone bands, Auto/Headphones/Speakers modes, separate
per-mode strength, channel separation and output trim. Audiogram compensation
starts disabled with zero thresholds; enter existing measured dB HL values in
the editor and save them to use it. The prescription is inspired by
[omarchy-audiogram-eq](https://github.com/Fail-Safe/omarchy-audiogram-eq).
Native Rust computes gains, filter responses and estimated headroom, including
overlapping bands. Automatic attenuation is not a limiter.

PipeWire and WirePlumber 0.5+ are required for processing. One primary runtime
owns a standalone filter-chain client, managed by WirePlumber's smart-filter
policy. It follows the default output without changing that default or restarting
audio services. Controls update in one debounced batch. Disabling removes the
filter; hidden panels keep processing while enabled and do not poll. Internal
filter nodes are excluded from Sound's device and app controls. Configuration
is kept in two bounded files under Morf's state directory:
`eva-equalizer.json` and `equalizer-runtime.conf`, both overwritten.
