"""Validate the native Pufflet export without changing its name or contents."""
from pathlib import Path
import plistlib
import sys


def canonical_app(directory):
    root = Path(directory)
    apps = list(root.glob('*.app'))
    if len(apps) != 1 or apps[0].is_symlink() or not apps[0].is_dir():
        raise ValueError('Expected exactly one top-level Pufflet app')
    app = apps[0]
    if app.name != 'Pufflet.app':
        raise ValueError('Unexpected Cloud app export name')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = dict(CFBundleIdentifier='me.balaj.SteamLibrary', CFBundleName='Pufflet',
                    CFBundleDisplayName='Pufflet', CFBundleExecutable='Pufflet')
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError('Cloud app does not match the Pufflet product')
    return app


if __name__ == '__main__':
    print(canonical_app(sys.argv[1]))
