import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, access, rm, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));

test('ordinary build hooks have no runtime download/bootstrap/signing path', async () => {
  const hook = await readFile(join(root, 'ci_scripts/ci_post_clone.sh'), 'utf8');
  const phase = await readFile(join(root, 'Runtime/bundle-runtime.sh'), 'utf8');
  const project = await readFile(join(root, 'project.yml'), 'utf8');
  assert.doesNotMatch(hook, /bootstrap-runtime|bundle-runtime|curl|wget/);
  assert.doesNotMatch(phase, /bootstrap-runtime|sign-runtime\.py|RuntimeSource|curl|wget|rsync/);
  assert.match(phase, /codesign --force --sign "\$EXPANDED_CODE_SIGN_IDENTITY" --options runtime/);
  assert.doesNotMatch(phase, /--entitlements|disable-library-validation/);
  assert.doesNotMatch(project, /name: Bundle Wine|Runtime\/sign-runtime\.py|Runtime\/Wine.entitlements/);
  assert.match(project, /excludes: \[libSteamLibraryDock.dylib\]/);
});

test('offline build phase copies only the native bridge and cleans marked old runtime output', async () => {
  const temporary = await mkdtemp(join(tmpdir(), 'pufflet-build-'));
  try {
    const contents = join(temporary, 'Pufflet.app/Contents');
    for (const directory of ['SharedSupport/wine', 'SharedSupport/renderer', 'Frameworks/GStreamer.framework', 'Frameworks/Sparkle.framework', 'Resources']) {
      await mkdir(join(contents, directory), { recursive: true });
    }
    await writeFile(join(contents, 'SharedSupport/.runtime-bundled'), 'legacy');
    await writeFile(join(contents, 'Frameworks/libLegacyRuntime.dylib'), 'old');
    await writeFile(join(contents, 'Frameworks/Sparkle.framework/marker'), 'keep');
    const bin = join(temporary, 'bin'); await mkdir(bin);
    // Any accidental source/download subprocess fails this build check.
    for (const command of ['curl', 'wget', 'python3', 'rsync']) {
      await writeFile(join(bin, command), '#!/bin/sh\nexit 99\n'); await chmod(join(bin, command), 0o755);
    }
    execFileSync('/bin/sh', [join(root, 'Runtime/bundle-runtime.sh')], {
      env: { ...process.env, PATH: bin + ':/usr/bin:/bin', TARGET_BUILD_DIR: temporary,
        CONTENTS_FOLDER_PATH: 'Pufflet.app/Contents', UNLOCALIZED_RESOURCES_FOLDER_PATH: 'Pufflet.app/Contents/Resources', CODE_SIGNING_ALLOWED: 'NO' }
    });
    assert.deepEqual(await readFile(join(contents, 'Resources/libSteamLibraryDock.dylib')), await readFile(join(root, 'Resources/libSteamLibraryDock.dylib')));
    assert.equal(await readFile(join(contents, 'Frameworks/Sparkle.framework/marker'), 'utf8'), 'keep');
    for (const obsolete of ['SharedSupport/wine', 'SharedSupport/renderer', 'SharedSupport/.runtime-bundled', 'Frameworks/libLegacyRuntime.dylib', 'Frameworks/GStreamer.framework']) {
      await assert.rejects(access(join(contents, obsolete)));
    }
  } finally { await rm(temporary, { recursive: true, force: true }); }
});
