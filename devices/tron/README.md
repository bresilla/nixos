# Custom Z790 (hostname `tron`)

Desktop with an i7-13700KF and an RTX 4080, on the workstation profile. It compiles what
other machines must not: kernels through `make kernels` in bresilla/devices, and x86_64
builds for devices that send them here. It is also a muros CI builder over cicd0
(`ci-builder.json`) and the first dump target: nest pushes its snapshots each night to
the 4 TB SSD at `/mnt/dump/tron`, as the `dump` user that may only run btrbk's filtered
commands and `dump-target`.

Hardware support lives under `custom-z790/` in
[bresilla/devices](https://github.com/bresilla/devices).
