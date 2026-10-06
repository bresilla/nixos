#!/usr/bin/env python3
"""Test the patched Cage itself using headless outputs, never the local display.

Usage: test-cage-phone.py /path/to/cage /directory/with/wlopm-wtype-wlr-randr
"""
import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

CAGE = str(Path(sys.argv[1]).resolve())
TOOLS = Path(sys.argv[2]).resolve()


@contextlib.contextmanager
def compositor(phone):
    with tempfile.TemporaryDirectory(prefix="cage-phone-test-") as runtime:
        env = dict(os.environ, XDG_RUNTIME_DIR=runtime,
                   WLR_BACKENDS="headless", WLR_RENDERER="pixman")
        for name in ("WAYLAND_DISPLAY", "DISPLAY", "CAGE_PHONE_IDLE_SECONDS"):
            env.pop(name, None)
        if phone:
            env["CAGE_PHONE_IDLE_SECONDS"] = "2"
        with tempfile.TemporaryFile(mode="w+") as log:
            process = subprocess.Popen([CAGE, "-D"], env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    sockets = [p for p in Path(runtime).glob("wayland-*") if p.is_socket()]
                    if sockets:
                        break
                    if process.poll() is not None:
                        raise AssertionError("Cage exited during startup")
                    time.sleep(0.05)
                else:
                    raise AssertionError("No Wayland socket")
                env["WAYLAND_DISPLAY"] = sockets[0].name

                def run(program, *args):
                    return subprocess.check_output([str(TOOLS / program), *args],
                                                   env=env, text=True, timeout=5).strip()
                yield run
                assert process.poll() is None, "Cage died during power changes"
            except BaseException:
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def expect_power(run, state):
    for _ in range(20):
        output = run("wlopm")
        if output.endswith(" " + state):
            return
        time.sleep(0.05)
    raise AssertionError(f"Expected {state}, got {output!r}")


with compositor(phone=True) as run:
    expect_power(run, "on")
    time.sleep(2.2)
    expect_power(run, "off")
    layout = json.loads(run("wlr-randr", "--json"))
    assert layout and layout[0]["enabled"], "Power-off removed the display from the layout"
    print("PASS: idle powers off without removing the output")

    run("wtype", "-k", "a")
    expect_power(run, "on")
    print("PASS: input wakes the panel")

    run("wtype", "-k", "XF86PowerOff")
    expect_power(run, "off")
    time.sleep(0.3)
    expect_power(run, "off")
    run("wtype", "-k", "XF86PowerOff")
    expect_power(run, "on")
    print("PASS: power press/release toggles once in each direction")

    time.sleep(1.2)
    run("wtype", "-k", "a")
    time.sleep(1.2)
    expect_power(run, "on")
    time.sleep(1.2)
    expect_power(run, "off")
    print("PASS: input resets the idle timer")

with compositor(phone=False) as run:
    time.sleep(2.2)
    run("wtype", "-k", "XF86PowerOff")
    expect_power(run, "on")
    print("PASS: phone policy is disabled unless explicitly requested")
