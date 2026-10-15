import io
from pathlib import Path
import runpy
import tarfile
import tempfile
import unittest

manifest = runpy.run_path(str(Path(__file__).with_name('runtime-artifact.py')))['manifest']
root = 'PuffletRuntime.app/'
required = ['Contents/Info.plist', 'Contents/CodeResources', 'Contents/MacOS/PuffletRuntime',
            'Contents/SharedSupport/wine/bin/wine']


class RuntimeArtifactTests(unittest.TestCase):
    def write(self, path, extra=(), omit=()):
        with tarfile.open(path, 'w:xz') as tar:
            for name in required:
                if name in omit:
                    continue
                entry = tarfile.TarInfo(root + name)
                entry.mode, entry.size = 0o755, 4
                tar.addfile(entry, io.BytesIO(b'test'))
            for entry in extra:
                tar.addfile(entry, io.BytesIO(b'') if entry.isfile() else None)

    def test_own_immutable_url_and_pin_with_internal_framework_links(self):
        link = tarfile.TarInfo(root + 'Contents/Frameworks/GStreamer.framework/Versions/Current')
        link.type, link.linkname = tarfile.SYMTYPE, '1.0'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runtime.tar.xz'
            self.write(path, [link])
            result = manifest(path, 'wine-11.0-dxmt-1')
            self.assertEqual(result['sizeBytes'], path.stat().st_size)
            self.assertEqual(result['teamIdentifier'], 'W7TT249CUU')
            self.assertEqual(len(result['sha256']), 64)
            self.assertGreater(result['expandedSizeBytes'], 16)
            self.assertEqual(result['url'], 'https://github.com/talhabalaj/pufflet/releases/download/runtime-wine-11.0-dxmt-1/PuffletRuntime-wine-11.0-dxmt-1.tar.xz')

    def test_unsafe_archive_members_fail_closed(self):
        cases = []
        for name in ['../outside', '/absolute', '._PuffletRuntime.app', root + 'Contents/../escape',
                     root + 'Contents//alias', root + 'Contents/new\nline', root + 'Contents/Info.plist']:
            cases.append([tarfile.TarInfo(name)])
        hard = tarfile.TarInfo(root + 'hard')
        hard.type, hard.linkname = tarfile.LNKTYPE, root + 'Contents/Info.plist'
        cases.append([hard])
        external = tarfile.TarInfo(root + 'external')
        external.type, external.linkname = tarfile.SYMTYPE, '../../outside'
        cases.append([external])
        internal = tarfile.TarInfo(root + 'link')
        internal.type, internal.linkname = tarfile.SYMTYPE, 'Contents'
        cases.append([internal, tarfile.TarInfo(root + 'link/new-file')])
        device = tarfile.TarInfo(root + 'device')
        device.type = tarfile.CHRTYPE
        cases.append([device])
        for entries in cases:
            with self.subTest(entries=[e.name for e in entries]), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'runtime.tar.xz'
                self.write(path, entries)
                with self.assertRaises(ValueError):
                    manifest(path, 'wine-11.0-dxmt-1')

    def test_ticket_is_required_and_version_must_be_immutable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runtime.tar.xz'
            self.write(path, omit=['Contents/CodeResources'])
            with self.assertRaisesRegex(ValueError, 'stapled ticket'):
                manifest(path, 'wine-11.0-dxmt-1')
            with self.assertRaisesRegex(ValueError, 'version'):
                manifest(path, '../latest')


if __name__ == '__main__':
    unittest.main()
