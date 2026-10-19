import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

// Compile the production updater and model activity expressions with inert
// collaborators. No app host, Sparkle installation, Wine, preferences or data.
test('update restart waits for desktop activity and resumes once all work ends', {
  skip: process.platform !== 'darwin',
}, async () => {
  const temporary = await mkdtemp('/private/tmp/pufflet-updater-test-');
  try {
    const [updater, model, runtime, fixture] = await Promise.all([
      readFile(new URL('../Sources/AppUpdater.swift', import.meta.url), 'utf8'),
      readFile(new URL('../Sources/LibraryModel.swift', import.meta.url), 'utf8'),
      readFile(new URL('../Sources/SteamRuntime.swift', import.meta.url), 'utf8'),
      readFile(new URL('./Fixtures/updater-activity.swift', import.meta.url), 'utf8'),
    ]);
    const snapshot = runtime.slice(runtime.indexOf('nonisolated struct WindowsProcess'), runtime.indexOf('nonisolated struct SteamRuntime'));
    // An absent predicate allows the old updater to compile and fail on its
    // behavior; once introduced, test its actual expression rather than a copy.
    const predicate = model.match(/    var shouldPostponeUpdate: Bool \{[\s\S]*?\n    \}/)?.[0] ?? '';
    const isPlaying = model.match(/    func isPlaying\(_ game: SteamGame\) -> Bool \{[^\n]+\}/)?.[0];
    assert.ok(isPlaying);
    const launchStart = model.indexOf('            if case let .launching(id) = phase,\n');
    const launchEnd = model.indexOf('\n            }\n', launchStart);
    assert.ok(launchStart !== -1 && launchEnd > launchStart);
    const launchObservation = model.slice(launchStart, launchEnd + '\n            }\n'.length);
    const source = fixture
      .replace('// PRODUCTION_MODEL_ACTIVITY', predicate + '\n' + isPlaying)
      .replace('// PRODUCTION_LAUNCH_OBSERVATION', launchObservation)
      .replace('// PRODUCTION_OBSERVATION', predicate ? '_ = model.shouldPostponeUpdate' : '_ = model.phase')
      .replace('// PRODUCTION_SNAPSHOT', snapshot)
      .replace('// PRODUCTION_UPDATER', updater.replace(/^import (AppKit|Sparkle)\n/gm, ''));
    await writeFile(join(temporary, 'main.swift'), source);
    execFileSync('swiftc', ['-module-cache-path', join(temporary, 'modules'), join(temporary, 'main.swift'), '-o', join(temporary, 'probe')], { timeout: 60_000, stdio: 'pipe' });
    let output;
    try {
      output = execFileSync(join(temporary, 'probe'), { timeout: 10_000, encoding: 'utf8' });
    } catch (error) {
      assert.fail(`Updater simulation failed:\n${error.stdout ?? ''}${error.stderr ?? ''}`);
    }
    assert.match(output, /PASS: updater activity regressions/);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test('pending update reevaluation observes the shared activity predicate', async () => {
  const app = await readFile(new URL('../Sources/SteamLibraryApp.swift', import.meta.url), 'utf8');
  assert.ok(/\.onChange\(of: model\.shouldPostponeUpdate\) \{ AppUpdater\.shared\.resumePendingInstall\(\) \}/.test(app),
    'Pending installation must be reevaluated when the shared activity predicate changes');
});

test('every live Steam snapshot recognizes the configured desktop client', async () => {
  const model = await readFile(new URL('../Sources/LibraryModel.swift', import.meta.url), 'utf8');
  // Steam-exit waits would treat a client outside a "Steam" folder as closed.
  const calls = [...model.matchAll(/SteamRuntime\.snapshot\(([^)]*)\)/g)];
  assert.ok(calls.length >= 3, 'Expected the observation loop and the Steam-exit waits');
  for (const [call, argument] of calls) {
    assert.match(argument, /steamExecutable:/, `${call} must pass the configured client executable`);
  }
  assert.match(model, /let current = await SteamRuntime\.snapshot\(steamExecutable: desktopSteamExecutable, runtimeRoots: roots\)\s*\n\s*if current != snapshot \{ snapshot = current \}/,
    'The scoped model snapshot must keep the configured client executable');
});
