# Microsoft Surface Pro 5 (hostname `surf`)

i5-7300U with 4 GB, on the laptop profile.

Hardware support lives under `microsoft-surfacepro5/` in
[bresilla/devices](https://github.com/bresilla/devices).

`default.nix` enables iptsd's `Touchscreen.DisableOnStylus`: all touchscreen
contacts are ignored while the pen is in proximity (including hover), and touch
returns one second after the pen leaves range. Briefly returning to proximity
restarts that delay on the next exit. `DisableOnStylusDelay` is in milliseconds.

The patched daemon lives in `packages/compiled/iptsd/`, is exposed as
`packages#iptsd`, and is selected through `shared/programs/iptsd.nix`. The package
workflow builds it, runs its timing checks, and publishes the cache pin used by
future updates. No compositor commands or additional session service are used.
