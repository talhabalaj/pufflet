"""Print only display-related game registry values, never account settings.

Production reads are restricted to the explicitly authorized user.reg.
"""
import pathlib, re, sys
root = pathlib.Path.home() / 'Library/Application Support'
for name in sys.argv[1:] or ['PuffletDev']:
    assert name in ['PuffletDev', 'Pufflet']
    for filename in (['user.reg', 'system.reg'] if name == 'PuffletDev' else ['user.reg']):
        path = root/name/'prefix'/filename
        if not path.exists(): continue
        print(f'## {name}/prefix/{filename}')
        selected = False
        for line in path.read_text(errors='replace').splitlines():
            if line.startswith('['):
                selected = bool(re.search(r'Muck|over.the.hill|Peggle', line, re.I))
                if selected: print(line)
            elif selected and 'GUID' not in line and re.search(r'^"[^"=]*(?:Screen|Resolution|Window|Fullscreen|Display|Width|Height)', line, re.I):
                print(line)
