import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = path => readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');
const project = read('SteamLibrary.xcodeproj/project.pbxproj');

test('the SteamLibrary target references Pufflet.app independently of its target name', () => {
  const target = project.match(/\w+ \/\* SteamLibrary \*\/ = \{\s*isa = PBXNativeTarget;([\s\S]*?)\n\t\t\};/)[1];
  const reference = target.match(/productReference = (\w+)/)[1];
  const product = project.match(new RegExp(`${reference} /\\* Pufflet\\.app \\*/ = \\{([^}]+)\\}`))[1];
  assert.match(product, /path = Pufflet\.app;/);
  assert.match(target, /name = SteamLibrary;/);
  assert.match(read('project.yml'), /SteamLibrary:\s+type: application\s+platform: macOS[\s\S]*?\n    productName: Pufflet\n/);
});

test('Release and Debug retain their names, bundle IDs, module and test hosts', () => {
  for (const [configuration, name, identifier] of [
    ['Release', 'Pufflet', 'me.balaj.SteamLibrary'],
    ['Debug', '"Pufflet Dev"', 'me.balaj.SteamLibrary.dev'],
  ]) {
    const settings = project.match(new RegExp(`\\w+ /\\* ${configuration} \\*/ = \\{\\s*isa = XCBuildConfiguration;\\s*buildSettings = \\{([^}]*PRODUCT_MODULE_NAME = SteamLibrary;[^}]*)\\}`))[1];
    assert.ok(settings.includes(`PRODUCT_NAME = ${name};`));
    assert.ok(settings.includes(`PRODUCT_BUNDLE_IDENTIFIER = ${identifier};`));
  }
  assert.ok(project.includes('TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Pufflet.app/Contents/MacOS/Pufflet";'));
  assert.ok(project.includes('TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Pufflet Dev.app/Contents/MacOS/Pufflet Dev";'));
  assert.doesNotMatch(project, /\b(?:EXECUTABLE_NAME|WRAPPER_NAME) =/);
});

test('the existing Cloud target and shared scheme retain their identity', () => {
  const scheme = read('SteamLibrary.xcodeproj/xcshareddata/xcschemes/SteamLibrary.xcscheme');
  const appReferences = [...scheme.matchAll(/<BuildableReference\b[^>]*BlueprintName = "SteamLibrary"[^>]*>/g)];
  assert.ok(appReferences.length > 0);
  for (const [reference] of appReferences) {
    assert.match(reference, /BuildableName = "Pufflet\.app"/);
    assert.match(reference, /BlueprintIdentifier = "D061A15CE20F62406EB0BE05"/);
  }
  assert.match(scheme, /<ArchiveAction\s+buildConfiguration = "Release"/);
  assert.match(scheme, /<LaunchAction\s+buildConfiguration = "Debug"/);
  const manifest = JSON.parse(read('SteamLibrary.xcodeproj/xcshareddata/xcodecloud/manifest.json'));
  assert.deepEqual(manifest.targets, [{ id: '33095b22-cf8f-444b-a4f1-85e42426f0cf', name: 'SteamLibrary' }]);
});
