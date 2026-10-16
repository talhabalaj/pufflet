"""User-approved input to an already running Dev game; never launches a game."""
import importlib.util, pathlib, re, subprocess, sys
root = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('display_probe', root/'probe.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
title, x, y = sys.argv[1:]
listing = subprocess.check_output(['/tmp/pufflet-real-game-ui'], text=True)
pid = None
for block in re.split(r'(?=pid=)', listing):
    if f'title={title} bounds=' in block:
        pid = re.match(r'pid=(\d+)', block)[1]
        break
if pid is None: raise SystemExit('No exact Dev game window')
# This refuses secure-input sessions and verifies the target is foreground.
subprocess.run(['/tmp/pufflet-real-game-ui', pid, 'foreground'], check=True)
r = m.run([str(m.wine/'bin/wine'), '/tmp/pufflet-game-input.exe', title, x, y])
print(r)
raise SystemExit(r['exit'])
