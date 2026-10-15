"""Validate the runtime tar contract and write the pin shipped inside the app."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
import sys
import tarfile


def manifest(archive, version):
    if not re.fullmatch(r'wine-[0-9]+\.[0-9]+-dxmt-[1-9][0-9]*', version):
        raise ValueError('Invalid immutable runtime version')
    links = set()
    entries = set()
    expanded = 0
    with tarfile.open(archive, 'r:xz') as tar:
        for entry in tar:
            name = entry.name.rstrip('/')
            path = PurePosixPath(name)
            if (not path.parts or path.parts[0] != 'PuffletRuntime.app' or path.is_absolute()
                or str(path) != name or '..' in path.parts or any(ord(char) < 32 for char in name)
                or name in entries or entry.mode & 0o6000):
                raise ValueError('Unsafe runtime archive path or permissions')
            if entry.issym():
                target = posixpath.normpath(posixpath.join(str(path.parent), entry.linkname))
                if (entry.linkname.startswith('/') or not target.startswith('PuffletRuntime.app/')
                    or any(ord(char) < 32 for char in entry.linkname)):
                    raise ValueError('External runtime symlink')
                links.add(name)
            elif entry.isfile():
                expanded += entry.size
            elif not entry.isdir():
                raise ValueError('Runtime archive contains hard links or special files')
            entries.add(name)
    for name in entries:
        if any(str(parent) in links for parent in PurePosixPath(name).parents):
            raise ValueError('Runtime archive entry is nested underneath a symlink')
    required = {'PuffletRuntime.app/Contents/Info.plist', 'PuffletRuntime.app/Contents/CodeResources',
        'PuffletRuntime.app/Contents/MacOS/PuffletRuntime', 'PuffletRuntime.app/Contents/SharedSupport/wine/bin/wine'}
    if not required.issubset(entries):
        raise ValueError('Runtime archive lacks its wrapper, Wine, or stapled ticket')
    digest = hashlib.sha256()
    with open(archive, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return dict(schemaVersion=1, version=version,
        url=f'https://github.com/talhabalaj/pufflet/releases/download/runtime-{version}/PuffletRuntime-{version}.tar.xz',
        sha256=digest.hexdigest(), sizeBytes=Path(archive).stat().st_size,
        expandedSizeBytes=expanded + len(entries) * 4096 + 64 * 1024 * 1024,
        bundleName='PuffletRuntime.app', teamIdentifier='W7TT249CUU')


if __name__ == '__main__':
    archive, output, version = sys.argv[1:]
    Path(output).write_text(json.dumps(manifest(archive, version), indent=2) + '\n')
