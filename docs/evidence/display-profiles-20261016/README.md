# Display profiles: isolated verification, 2026-10-16

108 native tests in 20 suites passed with the optional picker preview enabled;
the real-Wine XCTest test was disabled in that run. Regression coverage includes
per-game persistence, frozen/custom/missing inheritance, corrupt or unwritable
settings, profile restart/reuse, submitted and paused downloads, failed writes
and mismatched verification, duplicate Play, concurrent install/shutdown, and
cancellation, and runtime replacement during the final verification stop. Existing runtime/account/library/generation tests also passed.

The native [picker capture](picker.png) was rendered in an isolated XCTest window.
Its layout was inspected; this is a component rendering check, not a real-game
or interactive menu acceptance test.

The standalone `scripts/ci/check-display-profiles.swift` was compiled with the
production Swift runtime/display sources and run against the installed Wine 11.0
runtime as read-only input. It created one temporary prefix, bootstrapped Windows,
and verified these sequential transitions with production import/stop/readback:

| Transition | RetinaMode | LogPixels | Extra cold query |
| --- | --- | --- | --- |
| 1 | `y` | 96 | Match |
| 2 | `n` | 96 | Match |
| 3 | `  custom value  ` (spaces preserved) | 144 | Match |
| 4 | Absent | Absent | Match |
| 5 | `n` | 96 | Match |

All five transitions passed. The verifier confirmed server exit after each one.
A final soft-stop and process audit found no remaining clients for its prefix.
The disposable root was removed afterward. No Dev/production prefix, game
content, credentials, or live Steam session was used.

An earlier hosted XCTest attempt of these longer transitions ended when the test
host exited with code 0 before finishing. That run is not counted as passed;
the standalone check avoids using the shared Debug app identity. A separate
Xcode attempt also failed to launch the test runner via LaunchServices, before
running assertions; successful runs are reported above.

Cleanup also found 42 orphan clients from two earlier disposable persistence
probe roots whose directories had already been removed. Prefix soft-stop and
exact-client SIGTERM were attempted; six proven-owned winedevice clients needed
an exact-PID fallback. No wineserver was hard-killed during this cleanup. These
roots and the failed offline test roots had zero remaining clients in the final
audit. Other prefixes were left untouched.

These results establish stored configuration and lifecycle behavior only.
Over the Hill rendering, authenticated Steam/game launch, saves, cloud,
real download transitions and isolated per-game prefixes remain unverified.
