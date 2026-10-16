from pathlib import Path
import plistlib
import runpy
import tempfile
import unittest
canonical_app = runpy.run_path(str(Path(__file__).with_name('cloud-app.py')))['canonical_app']

class CloudAppTests(unittest.TestCase):
    def make(self, root, name='Pufflet.app', **overrides):
        app = Path(root) / name
        (app / 'Contents').mkdir(parents=True)
        info = dict(CFBundleIdentifier='me.balaj.SteamLibrary', CFBundleName='Pufflet',
                    CFBundleDisplayName='Pufflet', CFBundleExecutable='Pufflet')
        info.update(overrides)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        return app

    def test_product_named_export_preserves_path_and_contents(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.make(root)
            before = (app / 'Contents/Info.plist').read_bytes()
            (app / 'Contents/Updater.app').mkdir()
            result = canonical_app(root)
            self.assertEqual(result, app)
            self.assertEqual((result / 'Contents/Info.plist').read_bytes(), before)

    def test_scheme_named_export_is_rejected_without_renaming(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.make(root, 'SteamLibrary.app')
            with self.assertRaisesRegex(ValueError, 'export name'):
                canonical_app(root)
            self.assertTrue(app.is_dir())
            self.assertFalse((Path(root) / 'Pufflet.app').exists())

    def test_wrong_product_and_ambiguous_exports_are_rejected(self):
        for mode in ['name', 'identity', 'executable', 'multiple', 'symlink']:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as root:
                app = self.make(root, 'Other.app' if mode == 'name' else 'Pufflet.app',
                    **({'CFBundleIdentifier':'other'} if mode == 'identity' else {'CFBundleExecutable':'other'} if mode == 'executable' else {}))
                if mode == 'multiple': self.make(root, 'SteamLibrary.app')
                if mode == 'symlink':
                    app.rename(Path(root) / 'original')
                    app.symlink_to('original', target_is_directory=True)
                with self.assertRaises(ValueError): canonical_app(root)
