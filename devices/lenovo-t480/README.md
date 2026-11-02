# ThinkPad T480 (hostname `nova`)

Laptop on the laptop profile, with an XMM7360 modem.

Hardware support lives under `lenovo-t480/` in
[bresilla/devices](https://github.com/bresilla/devices).

The kernel is pinned in that repository's `lenovo-t480/kernel/` and published
to `/kernels` before device recipes are released. Do not add `kernelNixpkgs`
here: the hardware module selects the cached kernel, including the coreboot
radio-switch workaround.
