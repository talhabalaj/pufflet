"""Print only display-related game registry values, never account settings."""
import pathlib, re, sys
root = pathlib.Path.home() / 'Library/Application Support'
for name in sys.argv[1:] or ['PuffletDev']:
    assert name in ['PuffletDev', 'Pufflet']
    print(f'## {name}/prefix/user.reg')
    selected = False
    for line in (root/name/'prefix/user.reg').read_text(errors='replace').splitlines():
        if line.startswith('['):
            selected = bool(re.search(r'Muck|over.the.hill|Peggle', line, re.I))
            if selected:
                print(line)
        elif selected and 'GUID' not in line and re.search(r'^"[^"=]*(?:Screen|Resolution|Window|Fullscreen|Display|Width|Height)', line, re.I):
            print(line)
