# Lifecycle + renderer integration acceptance

Production code: `005cd10`, which merges main `3a82622` into the published
lifecycle commit `6983d5f` without rewriting its ancestry. This follow-up changes
only tests and evidence. It does not include #19 display profiles or #20 process
cleanup, and is not acceptance of those changes.

## Results (2026-10-16)

| Check | Result | What it establishes |
| --- | --- | --- |
| Normal Debug app + XCTest bundle build | PASS | Both targets compile with the original bundle ID/product name. |
| Full Swift suite, direct Swift Testing runner | 106 tests / 20 suites PASS | Production library + repository test sources; opt-in Steam/game checks disabled. |
| Node tooling suite | 39 tests PASS | `node --test scripts/ci/*.test.mjs Tests/*.test.mjs`. |
| Real Wine, new-prefix provisioning | PASS | Seed on/192, prepare as new, soft-stop, cold-read off/96; v2 record present; synthetic save file preserved. |
| Real Wine, existing-prefix preparation | PASS | Seed on/192 and old v1 marker, prepare as existing, soft-stop, cold-read on/192; no v2 record; synthetic save file preserved. |
| Real D3D12 sample | PASS | Actual SteamRuntime environment, Apple PE image identity, D3DMetal framework load, GPU fence and orange-pixel readback. |
| Native setup view capture/detection | PASS | Onboarding, toolkit missing/detected states, detection refresh and Skip preference assertions. |
| Final exact-prefix process audit | PASS | No processes remain from any Wine prefix started by this verification. |

The real Wine parameterized test passed both cases in 68.883 seconds. Its two
prefixes are disposable; only the already installed runtime binaries were read.
The D3D12 sample used a separate fresh prefix and the existing original offline
sample binary from #18. It passed in 13.410 seconds. Both paths use soft stop and
bounded server-exit verification. No Steam login, game installation, Dev-prefix
mutation, production data or real Steam library was involved. The save assertion
checks a synthetic sentinel file, not a real game's save/cloud behavior.

The focused renderer/lifecycle regressions also pass: DXMT → D3DMetal → DXMT
restarts an idle host; setup and registry queries keep DXMT; active and paused
downloads block a renderer switch; another account cannot stop an existing host;
and a delayed configuration read cannot validate a replacement session.

## Screenshot matrix

These are real native view captures and GPU output, not game crop/sharpness
verification. No account is loaded.

| Onboarding | Toolkit missing |
| --- | --- |
| ![Onboarding](onboarding.png) | ![Toolkit missing](toolkit-missing.png) |

| Toolkit detected | D3D12 GPU frame (800 × 500) |
| --- | --- |
| ![Toolkit detected](toolkit-detected.png) | ![GPU readback](d3d12-frame.png) |

## Execution boundary

`xcodebuild build-for-testing` succeeds. `xcodebuild test` and
`test-without-building` stalled before launching the test host, including an
unsandboxed run with an explicit arm64 destination. These stalled attempts are
not recorded as passing tests. Only the exact owned runners were canceled; no
shared macOS services or other agents' processes were stopped.

To obtain execution evidence, a temporary command-line runner invokes the
public `Testing.__swiftPMEntryPoint`, compiling the repository's test sources
unchanged and linking the built `Pufflet Dev.debug.dylib`/Swift module. It uses the
same Swift 6 default MainActor isolation and nonisolated async setting as the
project, with Xcode's Testing macro plugin/framework. Test resources are copied
from the build into the temporary runner directory. This bypasses Xcode's host
launch; it does not establish that Xcode host launch itself works. No bundle ID
or product name is overridden. All data-bearing test fixtures are isolated.

The first standalone native screenshot run exposed a fixture lifetime crash
while closing its window. `NSWindow.isReleasedWhenClosed = false` now leaves
ownership with Swift through deferred close. The repeated native view run
passed and all three captures were inspected.

Normal opt-in entry points remain `SteamDisplayDefaultsTests` with
`TEST_RUNNER_PUFFLET_OFFLINE_RUNTIME`, and `GameGraphicsTests` with the documented
D3DMetal/UI environment variables in `docs/D3DMETAL.md`. The temporary runner
uses the same variables without the `TEST_RUNNER_` forwarding prefix.

Authenticated Steam, game exit/save/cloud, literal Dock-menu acceptance (#20),
profile switching (#19), and the reported Over the Hill zoom are not verified
by this pass. The original investigation matrix and its failed/black captures
remain documented separately; this evidence does not convert them into passes.
