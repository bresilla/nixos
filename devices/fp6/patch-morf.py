"""Apply the verified embedded WGSL fix without changing the ELF layout."""
from pathlib import Path
import shutil
import stat
import sys


def patch_package(source, output, before, after):
    if not before or len(after) > len(before):
        raise ValueError("replacement must fit the original embedded shader")

    matches = []
    for name in ("bin/.morf-wrapped", "bin/morf"):
        path = source / name
        if path.is_file():
            data = path.read_bytes()
            count = data.count(before)
            if count:
                if count != 1 or not data.startswith(b"\x7fELF") or path.is_symlink():
                    raise ValueError(f"unexpected embedded shader layout in {path}")
                matches.append((name, data))

    if not matches:
        output.symlink_to(source, target_is_directory=True)
        print("Cached Morf has no affected shader; using it unchanged")
        return
    if len(matches) != 1:
        raise ValueError("affected shader appears in multiple executables")

    name, data = matches[0]
    wrapper = None
    if name == "bin/.morf-wrapped":
        launcher = source / "bin/morf"
        if launcher.is_symlink():
            raise ValueError("unexpected symlinked Morf launcher")
        wrapper = launcher.read_text()
        old_target = str(source / name)
        if wrapper.count(old_target) != 1:
            raise ValueError("Morf launcher does not reference the expected executable")
        wrapper = wrapper.replace(old_target, str(output / name))

    # Copy first; never modify a cached store output or follow its symlinks.
    shutil.copytree(source, output, symlinks=True)
    binary = output / name
    binary.chmod(binary.stat().st_mode | stat.S_IWUSR)
    binary.write_bytes(data.replace(before, after.ljust(len(before), b" ")))
    if wrapper is not None:
        launcher = output / "bin/morf"
        launcher.chmod(launcher.stat().st_mode | stat.S_IWUSR)
        launcher.write_text(wrapper)
    print("Applied the verified FP6 field shader repair to cached Morf")


if __name__ == "__main__":
    source, output, before, after = map(Path, sys.argv[1:])
    patch_package(source, output, before.read_bytes(), after.read_bytes())
