"""Read-only Dev-session registry/window/process probe; never launches a game.

Run only while holding scripts/dev-slot. Wine must already be running.
"""
import json, os, pathlib, re, subprocess, sys

support = pathlib.Path.home() / 'Library/Application Support/PuffletDev'
prefix = support / 'prefix'
runtime = support / 'Runtimes/wine-11.0-dxmt-2/PuffletRuntime.app/Contents'
wine = runtime / 'SharedSupport/wine'
env = dict(os.environ, WINEPREFIX=str(prefix), WINEDEBUG='-all',
           WINEESYNC='1', WINEMSYNC='1', WINEBOOT_HIDE_DIALOG='1')
env['DYLD_FALLBACK_LIBRARY_PATH'] = ':'.join(map(str, [wine/'lib', wine/'lib64', runtime/'Frameworks', pathlib.Path('/usr/lib')]))
env['WINEDLLPATH'] = ':'.join(str(wine/'lib/wine'/p) for p in ['x86_64-windows', 'i386-windows', 'x86_64-unix'])
env['WINEDLLPATH_DXMT'] = str(runtime/'SharedSupport/renderer/dxmt/wine')
env['WINEDLLPATH_PREPEND'] = env['WINEDLLPATH_DXMT']
env['SikarugirAppWine11'] = '1'
def run(args):
    p = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    return {'exit': p.returncode, 'output': p.stdout.replace(str(pathlib.Path.home()), '~')}

def probe():
    result = {}
    for name, key in [('retina', r'HKCU\Software\Wine\Mac Driver'), ('dpi', r'HKCU\Control Panel\Desktop')]:
        result[name] = run([str(wine/'bin/wine'), 'reg', 'query', key, '/v', 'RetinaMode' if name == 'retina' else 'LogPixels'])
    for name, path in [('desktop_and_windows', '/tmp/pufflet-real-games-display-probe.exe')]:
        result[name] = run([str(wine/'bin/wine'), path])
    for name, path in [('baseline', prefix/'.pufflet-display-baseline-v1.json'), ('preferences', support/'Display/preferences-v1.json')]:
        result[name] = json.loads(path.read_text()) if path.exists() else None
    ps = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True)
    result['processes'] = []
    for line in ps.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3 or not re.search(r'wine|\.exe$|Pufflet Dev', fields[2].strip(), re.I):
            continue
        pid, ppid, comm = fields
        full = subprocess.run(['ps', 'eww', '-p', pid], text=True, stdout=subprocess.PIPE).stdout
        if f'WINEPREFIX={prefix} ' in full or 'pufflet-real-games-build/' in comm:
            result['processes'].append({'pid': int(pid), 'ppid': int(ppid), 'command': comm.replace(str(pathlib.Path.home()), '~')})
    return result

if __name__ == "__main__":
    print(json.dumps(probe(), indent=2))
