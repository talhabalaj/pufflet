#!/usr/bin/env python3
"""Offline persistence probe. Always creates its own prefix; never reads Steam data."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    contents = args.runtime.resolve() / "Contents"
    wine = contents / "SharedSupport/wine"
    frameworks = contents / "Frameworks"
    with tempfile.TemporaryDirectory(prefix="pufflet-registry-probe-") as work:
        prefix = Path(work) / "prefix"
        prefix.mkdir(mode=0o700)
        env = {k: v for k, v in os.environ.items() if k in ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SECURITYSESSIONID")}
        env.update(WINEPREFIX=str(prefix), WINEDEBUG="-all", WINEBOOT_HIDE_DIALOG="1",
                   SikarugirAppWine11="1", WINEESYNC="1", WINEMSYNC="1",
                   PATH=str(wine / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
                   DYLD_FALLBACK_LIBRARY_PATH=":".join(map(str, [wine / "lib", wine / "lib64", frameworks,
                       frameworks / "GStreamer.framework/Libraries", "/usr/lib", "/usr/libexec", "/usr/lib/system"])),
                   WINEDLLPATH=":".join(str(wine / "lib/wine" / p) for p in ("x86_64-windows", "i386-windows", "x86_64-unix")))

        def run(exe, *arguments, check=True, timeout=45):
            # Wine services can inherit stdout after the launcher exits. Files
            # avoid waiting for an inherited pipe EOF from a persistent server.
            with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as error:
                result = subprocess.run([str(wine / "bin" / exe), *arguments], env=env,
                                        stdout=output, stderr=error, timeout=timeout)
                output.seek(0); error.seek(0)
                result.stdout = output.read().decode(errors="replace")
                result.stderr = error.read().decode(errors="replace")
                if check:
                    result.check_returncode()
                return result

        def stopped():
            run("wineserver", "-w", timeout=20)

        results = []
        try:
            run("wine", "wineboot.exe", "-u", timeout=120)
            run("wineserver", "-k", check=False)
            stopped()
            for method in ("hard", "soft", "graceful"):
                for repetition in range(3):
                    # Wine keeps the server briefly after the launcher exits;
                    # issue the stop immediately after the registry command.
                    run("wine", "cmd", "/c", "exit", "0")
                    name = f"{method}{repetition}"
                    key = r"HKCU\Software\PuffletPersistenceProbe"
                    run("wine", "reg", "add", key, "/v", name, "/t", "REG_DWORD", "/d", "192", "/f")
                    began = time.monotonic()
                    if method != "graceful":
                        run("wineserver", "-k9" if method == "hard" else "-k", check=False)
                    exited = True
                    try:
                        run("wineserver", "-w", timeout=3)
                    except subprocess.TimeoutExpired:
                        exited = False
                        run("wineserver", "-k", check=False)
                        stopped()
                    query = run("wine", "reg", "query", key, "/v", name, check=False)
                    survived = (query.returncode == 0 and "0xc0" in query.stdout.lower()) if exited else None
                    result = dict(method=method, repetition=repetition, exited=exited, survived=survived,
                                  stopAndReadbackSeconds=round(time.monotonic() - began, 3))
                    results.append(result)
                    print(json.dumps(result), flush=True)
                    args.output.write_text(json.dumps(results, indent=2) + "\n")
                    run("wineserver", "-k", check=False)
                    stopped()
        finally:
            # Only this disposable prefix. Never unscoped process-name kills.
            run("wineserver", "-k", check=False)
            run("wineserver", "-w", check=False, timeout=20)
    if not all(r["survived"] for r in results if r["method"] == "soft"):
        raise SystemExit("Soft-stop persistence failed; do not assume it is safe.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"{error.cmd} failed ({error.returncode}): {error.stdout[-1000:]} {error.stderr[-2000:]}") from error
