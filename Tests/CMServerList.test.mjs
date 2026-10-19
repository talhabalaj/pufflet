import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

// Exercise the production actor with memory-only preferences and intercepted HTTP.
// Compile copies so concurrent work and the app's data cannot affect the fixture.
test('CM discovery falls back to validated cache without swallowing cancellation', {
  skip: process.platform !== 'darwin',
}, async () => {
  const temporary = await mkdtemp('/private/tmp/pufflet-cm-test-');
  try {
    const files = [
      ['../Sources/SteamCatalogue/CMServerList.swift', 'CMServerList.swift'],
      ['../Sources/SteamAuth/SteamError.swift', 'SteamError.swift'],
      ['./Fixtures/cm-server-list.swift', 'Probe.swift'],
    ];
    for (const [source, destination] of files) {
      let contents = await readFile(new URL(source, import.meta.url), 'utf8');
      if (destination === 'CMServerList.swift') {
        // Age only the copied actor's timestamp to exercise the real stale path
        // without waiting an hour or adding a production testing API.
        contents += '\nextension CMServerList { func expireForFixture() { lastFetched = Date(timeIntervalSinceNow: -3601) }\n'
          + '  func ageForFixture(_ seconds: TimeInterval) { lastFetched = Date(timeIntervalSinceNow: -seconds) } }\n';
      }
      await writeFile(join(temporary, destination), contents);
    }
    execFileSync('swiftc', [
      '-swift-version', '6', '-default-isolation', 'MainActor',
      '-module-cache-path', join(temporary, 'modules'), '-parse-as-library',
      ...files.map(([, destination]) => join(temporary, destination)),
      '-o', join(temporary, 'probe'),
    ], { timeout: 60_000, stdio: 'pipe' });
    const output = execFileSync(join(temporary, 'probe'), { timeout: 15_000, encoding: 'utf8' });
    assert.match(output, /PASS: CM directory fallback regressions/);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});
