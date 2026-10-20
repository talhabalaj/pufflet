"""Sign bundled native runtime code inside-out before Xcode seals the app."""
import os
from pathlib import Path
import subprocess
import sys

contents = Path(sys.argv[1])
identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "")
if os.environ.get("CODE_SIGNING_ALLOWED") == "NO":
    sys.exit(0)
if not identity:
    raise SystemExit("A signing identity is required for the bundled runtime.")

magic = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}
roots = [contents / "SharedSupport", contents / "Frameworks", contents / "Resources"]
native = []
for root in roots:
    for path in root.rglob("*"):
        if "Sparkle.framework" in path.parts or path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) in magic:
                native.append(path)

for path in sorted(native, key=lambda p: len(p.parts), reverse=True):
    command = ["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime"]
    command += ["--timestamp"] if os.environ.get("CONFIGURATION") == "Release" else ["--timestamp=none"]
    if path == contents / "SharedSupport/wine/lib/wine/x86_64-unix/wine":
        # bin/wine is a symlink to this loader. It maps unsigned Windows PE code;
        # the exception belongs here, not on the launcher or native Dock bridge.
        command += ["--entitlements", str(Path(__file__).with_name("WindowsLoader.entitlements"))]
    elif path in [contents / "SharedSupport/wine/bin/wine", contents / "SharedSupport/wine/bin/wineserver"]:
        command += ["--entitlements", str(Path(__file__).with_name("Wine.entitlements"))]
    # The timestamp service occasionally drops a request; retry before failing.
    for attempt in range(3):
        if subprocess.run(command + [str(path)]).returncode == 0:
            break
    else:
        raise SystemExit(f"codesign failed for {path}")

print(f"Signed {len(native)} native runtime files.")
