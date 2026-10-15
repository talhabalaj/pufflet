"""Explicit runtime-packaging preflight; never used by normal app builds."""
import os
from pathlib import Path
import subprocess
import sys

contents = Path(sys.argv[1]).resolve() / "Contents"
prefix = Path(sys.argv[2]).resolve()
prefix.mkdir(mode=0o700)  # Require a fresh, private prefix; never use Steam data.
wine = contents / "SharedSupport/wine"
server = wine / "bin/wineserver"
base = {key: value for key, value in os.environ.items()
        if key in {"HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"}}
subprocess.run([str(server), "--version"], env=base, check=True, timeout=20)
environment = base | {
    "WINEPREFIX": str(prefix), "PATH": str(wine / "bin") + ":/usr/bin:/bin",
    "SikarugirAppWine11": "1", "WINEDEBUG": "-all", "WINEBOOT_HIDE_DIALOG": "1",
    "DYLD_FALLBACK_LIBRARY_PATH": ":".join(map(str, [wine / "lib", wine / "lib64",
        contents / "Frameworks", contents / "Frameworks/GStreamer.framework/Libraries", "/usr/lib"])),
}
log = prefix.parent / "windows-command.log"
process = None
try:
    with log.open("w") as output:
        process = subprocess.Popen([str(wine / "bin/wine"), "cmd", "/c", "ver"],
                                   env=environment, cwd=prefix,
                                   stdout=output, stderr=subprocess.STDOUT)
        if process.wait(timeout=120) != 0:
            raise RuntimeError(f"Windows command failed; inspect {log}")
finally:
    # WINEPREFIX selects only this new validation server and its processes.
    try:
        subprocess.run([str(server), "-k"], env=environment, timeout=15, check=True)
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=10)
print(log.read_text())
print("Fresh-prefix Windows command passed; validation server stopped.")
