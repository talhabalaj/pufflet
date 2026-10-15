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
roots = [contents / "SharedSupport", contents / "Frameworks"]
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
    if path in [contents / "SharedSupport/wine/bin/wine", contents / "SharedSupport/wine/bin/wineserver"]:
        command += ["--entitlements", str(Path(__file__).with_name("Wine.entitlements"))]
    subprocess.run(command + [str(path)], check=True)

framework = contents / "Frameworks/GStreamer.framework"
subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime",
                "--timestamp" if os.environ.get("CONFIGURATION") == "Release" else "--timestamp=none", str(framework)], check=True)
print(f"Signed {len(native)} native runtime files and GStreamer.framework.")
