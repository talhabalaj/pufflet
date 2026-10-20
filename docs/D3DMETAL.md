# D3D12 through Apple's D3DMetal

Research checked 16 October 2026. This document separates the archived original Whisky from newer unrelated forks, and the current Apple download from historical GPTK releases. No Apple binaries are added to Pufflet's repository or runtime.

> **Runtime update (20 October 2026):** from `wine-11.0-dxmt-3` Pufflet runs its own
> [pufflet-runtime](https://github.com/talhabalaj/pufflet-runtime), built from CrossOver
> 26.3 sources, instead of Sikarugir11.0_1. `GameGraphicsTests.offlineD3D12Sample` passed
> against it with GPTK 4.0b2 (Apple's `d3d12.dll` mapped, GPU fence and pixel readback).
> D3DMetal processes (`WINEDLLPATH_D3DMETAL` set) keep CrossOver's `%gs` scheme, because
> Apple's code calls native code directly from PE code; the Sikarugir-specific notes
> below describe the previous runtime.

## Decision

Use a user-provided GPTK evaluation environment, preserving its complete `redist/lib` layout. Select graphics per game; keep DXMT as the existing D3D10/11 route. D3DMetal needs a Wine build with Apple's/CrossOver's integration patches, not merely a sufficiently high Wine version. Validate the exact Pufflet runtime rather than replace it just because its version is 11.

**Redistribution is conditionally permitted, not categorically prohibited.** The inspected GPTK 4.0 beta 2 license permits non-commercial redistribution and explicitly allows the Framework or Redistributables separately. It does not grant a general commercial distribution right. This implementation uses user installation/import, avoiding a claim about Pufflet's commercial status and retaining Apple's own license acceptance/download. This choice does not expand the user's rights under Apple's license.

## Whisky maintenance date and scope

Original Whisky's [maintainer notice](https://docs.getwhisky.app/maintenance-notice.html), last changed **9 April 2025**, says active maintenance and WhiskyWine updates have ended, no Wine 8+ upgrade or app/game-specific fixes are planned, and directs users needing maintained compatibility to CrossOver. The notice links its [primary documentation commit `f157e66`](https://github.com/Whisky-App/whisky-book/commit/f157e66). This is the maintenance-announcement date. GitHub separately records the [application repository](https://github.com/Whisky-App/Whisky) as archived **11 May 2025**; those are different events. Neither should be presented as a 2026 cessation.

Whisky was a general-purpose Wine frontend with bottles for Windows applications and games, rather than a native Steam-only library. Its archived README explicitly describes installing and running both Windows apps and games. Pufflet's Steam library/sign-in/Dock flow is a separate product scope: borrowing Whisky's graphics integration does not require replacing it with a general bottle manager or importing Whisky's old Steam prefix.

## What the original Whisky actually shipped

Primary snapshots:

- [Whisky `fd5480a76b3ebfe3419a1ab86ca3695f5cc328f8`](https://github.com/Whisky-App/Whisky/tree/fd5480a76b3ebfe3419a1ab86ca3695f5cc328f8), the archived original application, not `frankea/Whisky`.
- [Whisky Wine `a92f7f06c4cff7291578e58eb95284b00e322799`](https://github.com/Whisky-App/wine/tree/a92f7f06c4cff7291578e58eb95284b00e322799), branch `7.7`, commit titled “Update to Release GPTK 2.1”. Its `VERSION` is Wine 7.7, `WhiskyWineVersion.plist` is 2.6.0, and the included framework's `version.plist` is D3DMetal 2.1. Whisky's [README](https://github.com/Whisky-App/Whisky/blob/fd5480a76b3ebfe3419a1ab86ca3695f5cc328f8/README.md) identifies CrossOver 22.1.1 as its base.

Whisky downloaded its **own combined runtime containing D3DMetal**, rather than requiring each user to install GPTK. [`WhiskyWineDownloadView`](https://github.com/Whisky-App/Whisky/blob/fd5480a76b3ebfe3419a1ab86ca3695f5cc328f8/Whisky/Views/Setup/WhiskyWineDownloadView.swift) downloads `https://data.getwhisky.app/Wine/Libraries.tar.gz`; [`WhiskyWineInstaller`](https://github.com/Whisky-App/Whisky/blob/fd5480a76b3ebfe3419a1ab86ca3695f5cc328f8/WhiskyKit/Sources/WhiskyKit/WhiskyWine/WhiskyWineInstaller.swift) extracts it under `~/Library/Application Support/com.isaacmarovitz.Whisky`.

This is independently proved by the Wine repository's checked-in [`GPTK/redist`](https://github.com/Whisky-App/wine/tree/a92f7f06c4cff7291578e58eb95284b00e322799/GPTK/redist) and [build workflow](https://github.com/Whisky-App/wine/blob/a92f7f06c4cff7291578e58eb95284b00e322799/.github/workflows/build.yml): “Install GPTK” performs `ditto GPTK/redist/lib/ Libraries/Wine/lib/`, then the workflow packages `Libraries.tar.gz`. The historical download host did not resolve during this investigation, so no claim is made that a newly downloaded archive was independently hashed today. The source packaging and included payload establish the intended bundle.

In that bundle:

```text
Libraries/Wine/lib/
  external/libd3dshared.dylib
  external/D3DMetal.framework/…
  wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi,atidxx64}.dll
  wine/x86_64-unix/{d3d10,d3d11,d3d12,dxgi,atidxx64}.so
```

The old Unix `.so` entries are symlinks to `../../external/libd3dshared.dylib`. D3DMetal is thus the runtime's **built-in** D3D implementation, not a normal Windows DLL that can be copied alone to `system32`. The patched [ntdll loader](https://github.com/Whisky-App/wine/blob/a92f7f06c4cff7291578e58eb95284b00e322799/dlls/ntdll/unix/loader.c) loads `@rpath/libd3dshared.dylib` and resolves `register_non_native_code_region` and `supports_non_native_code_regions`, demonstrating an actual Wine/Apple integration boundary.

### Choosing DXVK or D3DMetal

[`BottleSettings.swift`](https://github.com/Whisky-App/Whisky/blob/fd5480a76b3ebfe3419a1ab86ca3695f5cc328f8/WhiskyKit/Sources/WhiskyKit/Whisky/BottleSettings.swift) persists a bottle DXVK boolean. With DXVK enabled it sets `WINEDLLOVERRIDES=dxgi,d3d9,d3d10core,d3d11=n,b`. [`Wine.enableDXVK`](https://github.com/Whisky-App/Whisky/blob/fd5480a76b3ebfe3419a1ab86ca3695f5cc328f8/WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift) installs native DXVK DLLs into the bottle's `system32` (x64) and `syswow64` (x32). Without that native override the runtime's built-in Apple route is used. The graphics toggle is per bottle; the launch environment also accepts caller-supplied overrides. It is not original Whisky's automatic per-game D3D12 import detection.

Its optional flags include `D3DM_SUPPORT_DXR=1` for ray tracing, `ROSETTA_ADVERTISE_AVX=1`, and `MTL_HUD_ENABLED=1`. Its MSync setting also sets `WINEESYNC=1` because the source comments say D3DMetal detects ESync. These are feature/workaround flags, not an API that supplies D3D12 support to arbitrary Wine builds. Do not invent `D3DM_*` flags or transplant the old MSync workaround without testing the current runtime.

## Apple's current package and license

The [official GPTK page](https://developer.apple.com/games/game-porting-toolkit/) currently advertises **GPTK 4**. The exact package inspected locally was Apple's already-downloaded `Game_Porting_Toolkit_4.0_beta_2.dmg`, containing `Evaluation environment for Windows games 4.0 beta 2.dmg`. The nested image's `License.rtf`, `Read Me.rtf`, and framework `version.plist` were inspected read-only. The version plist says 4.0b2. This is evidence for **4.0 beta 2**, not a claim that every later beta/final has identical terms.

Reproducibility hashes (SHA-256):

- Outer Apple DMG: `03893ac4fab94ad9ff6aa32e887e2854bbf40fd90796f78a1d9bdbc02526ee5b`.
- Nested image `License.rtf`: `5abb2d059be217663b00e8fd37e14411d374e11d17e3b744eebd49b8d17118c8`.

Download the corresponding package from [Apple Downloads](https://developer.apple.com/download/all/?q=game%20porting%20toolkit) and read the license within the **evaluation environment** image. It remains marked `EA18380`, `8/17/2023`; the old date printed on this current package's license does not make it a GPTK 1-only license. Its definitions identify `D3DMetal.framework` as “Framework” and `/redist` components as “Redistributables”.

Section 2A(iii), verbatim:

> distribute the Apple Software solely for non-commercial purposes and in accordance with this Agreement, including Section 2C.

Section 2C, verbatim:

> Notwithstanding the foregoing, the Framework in its entirety or any part of the Redistributables may be distributed separately from the Apple Software. For clarity, all distribution of the Apple Software, including the Framework in its entirety and any individual Redistributables, are subject to the non-commercial restriction in Section 2(A)(iii).

Section 2A(i) limits installation/internal use/testing to developing, testing, or evaluating video games for Apple-branded products. Section 2C restricts non-Apple devices and services; section 2D restricts modification and reverse engineering, subject to its stated exceptions. Preserve the full framework, original signatures, license and notices; don't re-sign or patch Apple binaries. Whisky's historical redistribution and CrossOver's inclusion do not establish a separate license grant to Pufflet.

**Verdict for this change:** Pufflet could potentially bundle the permitted components for qualifying non-commercial distribution under all these conditions. We have not established that every future product/distribution model qualifies. Therefore Pufflet's shipping path here requires users to obtain GPTK from Apple and select their local copy; no Apple payload is downloaded from Pufflet infrastructure or redistributed with its runtime. The license itself does **not** force user-installation in every case.

## Current layout and runtime compatibility

The 4.0b2 evaluation image contains:

```text
License.rtf
Read Me.rtf
redist/lib/
  external/libd3dshared.dylib
  external/D3DMetal.framework/…
  wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi,nvapi64,nvngx-on-metalfx}.dll
  wine/x86_64-unix/{d3d10,d3d11,d3d12,dxgi,nvapi64,nvngx-on-metalfx}.so
```

Unlike the old 2.1 bundle these `.so` files are actual Mach-O shim libraries. `d3d12.so` references `@rpath/libd3dshared.dylib`; the Windows PE DLLs and Unix shims plus external framework belong together. Selecting `D3DMetal.framework` alone is insufficient. Preserve `redist/lib` as a unit instead of globally replacing DXMT's DLLs.

Apple's packaged README explicitly requires a custom Wine translation environment, Apple silicon, and macOS 15 or newer. It names Gcenx's prebuilt environments and CrossOver, and documents their existing `wine/lib` and `lib64/apple_gptk` layouts. Its current feature flags include `D3DM_SUPPORT_DXR`, `D3DM_ENABLE_METALFX`, `D3DM_MTL4`, and `D3DM_MAX_FPS`; these should remain defaults unless a game requires a specific setting.

A stock Wine 11 version string alone is **not** proof of compatibility. Pufflet uses Sikarugir11.0_1, whose actual shipped loader must be checked and tested. The public [Sikarugir Wine repository](https://github.com/Sikarugir-App/wine) master snapshot `455e3509b98a6919fd4ad1def4803e08c41c03b2` is tagged Wine 11.19 and is not necessarily the source of that older binary: do not infer its patches from today's master. The app must direct only the selected game's process tree to the Apple module directory, leaving DXMT/Steam defaults intact. The current implementation/runtime checks establish compatibility of **Pufflet's existing Sikarugir11.0_1 binary with the inspected GPTK 4.0b2**, without replacing or rebuilding Wine. This does not establish that an unpatched WineHQ Wine 11 build works.

The verified per-process route sets `WINEDLLPATH_D3DMETAL=<redist/lib/wine>` and `WINEDLLPATH_PREPEND=<redist/lib/wine>`, prepends `<redist/lib/external>` to `DYLD_FALLBACK_LIBRARY_PATH`, and requests built-in graphics modules with `WINEDLLOVERRIDES=d3d12,dxgi,d3d11=b` (merged with other required overrides). There are no global DLL copies or prefix backend edits.

As a corroborating integration example, [Aqua `6d20b0a19522bedf4f6ede64d5acd6ba83b9ce21` Wine.swift](https://github.com/M3BIONIX/Aqua/blob/6d20b0a19522bedf4f6ede64d5acd6ba83b9ce21/Sources/AquaCore/Wine.swift) uses Sikarugir's per-renderer variables for its Wine 10 fallback and `WINEDLLPATH_PREPEND` for its own CrossOver 26.3/Wine 11 build. Its checked-in [loader patch](https://github.com/M3BIONIX/Aqua/blob/6d20b0a19522bedf4f6ede64d5acd6ba83b9ce21/Engine/patches/0001-ntdll-winedllpath-prepend.patch) explicitly puts that path before Wine's bundled modules; ordinary `WINEDLLPATH` alone is searched too late to replace existing built-ins. Aqua additionally sets `CX_ACTIVE_GRAPHICS_BACKEND` and `CX_APPLEGPTK_LIBD3DSHARED_PATH`; those are not needed to establish Pufflet's already-verified route and are not added merely by analogy. Aqua is evidence for its own integration, not the source provenance of Sikarugir11.0_1's exact loader patch set. That complete patch provenance remains unestablished here.

Aqua's [prefix preparation](https://github.com/M3BIONIX/Aqua/blob/6d20b0a19522bedf4f6ede64d5acd6ba83b9ce21/Sources/AquaCore/Bottle.swift) also explains the placeholder prerequisite for modules Wine itself lacks. Pufflet's tested prefix already supplies normal D3D12/DXGI built-in placeholders; no renderer DLL replacement was needed.

## CrossOver and Madeira

[CrossOver's official macOS user guide](https://media.codeweavers.com/pub/crossover/docs/en/userguide-crossover-mac-23.pdf) documents per-bottle D3DMetal and DXVK controls; D3DMetal supports D3D11/12. Apple's current package README explicitly names CrossOver as a prebuilt environment that incorporates its evaluation layers. It is an integrated, maintained Wine product, whereas original Whisky froze on the much older CrossOver 22.1.1/Wine 7.7 base.

[Madeira's own D3D12 notes](https://github.com/willfaust/Madeira/blob/main/madeira-d3d12/README.md) describe a separate native D3D12-to-Metal implementation using Apple's Metal Shader Converter, explicitly distinct from Apple's D3DMetal and not using its implementation. Its canary/cube milestones demonstrate that implementation's progress; they are not proof that arbitrary DX12 games work or a drop-in macOS GPTK installation strategy. Pufflet's Steam/Dock integration from Madeira is independent of the graphics backend decision.

## Verification

The isolated D3D12 probe on this machine successfully created a D3D12 device and queried feature support with the existing runtime. Crucially, the loaded `d3d12` PE module reported `SizeOfImage=208896` and COFF timestamp `1783712738`, matching Apple's inspected 4.0b2 DLL. Wine's own D3D12 DLL differs (`SizeOfImage=94208`, timestamp `1790817215`). This rules out calling Wine's built-in VKD3D module and mistaking its device-creation success for Apple translation. A render sample also completed `ClearRenderTargetView`, `Present`, and GPU-fence synchronization; dyld recorded Apple's complete D3DMetal framework. Loading the framework at process startup or seeing the word “builtin” in Wine's log would not, on their own, prove which D3D12 implementation ran.

The precise test command, source and visible sample/UI screenshots are recorded alongside the implementation evidence. This sample establishes that the graphics path executes; it does not claim arbitrary DX12 game compatibility or Steam-account end-to-end validation. No runtime or GitHub release is published as part of this work.


## Pufflet implementation and verification evidence

- Each game persists `Auto`, `DXMT`, or `D3DMetal` independently. Auto inspects only the selected launch executable's normal and RVA-based delay PE import tables (bounded to a 128 MiB file and 4,096 descriptors). It recognizes `d3d12.dll` / `d3d12core.dll`; dynamic loading, another launcher, and larger executables require a manual choice.
- D3DMetal is referenced in place. Settings → Advanced → Add Toolkit… accepts the complete evaluation environment or its `redist/lib`; common local installation paths and mounted evaluation images are checked. No Apple payload is copied into Pufflet, its source tree, or its runtime artifact.
- First-run setup includes an optional skippable toolkit row, with a live two-second status refresh and the website guide. Skipping is remembered. A later Play attempt for a detected DX12 game (or an explicit D3DMetal selection) reopens the native prompt if the installation is missing. An Auto game otherwise resolves to DXMT; the missing-DX12 prompt prevents silently presenting that fallback as DX12 support.
- Prefix preparation retains the normal DXMT environment. Only the selected game's managed Steam host and its inherited game process tree receive the Apple module/library paths. No prefix-wide registry override or DLL replacement is made. Changing renderer restarts an idle host; a different renderer waits for active downloads/game work to finish. Downloads can continue in the same host without replacing a running game's renderer. Desktop Steam cannot reliably adopt another process's environment, so affected games are directed to native Play.
- Games use the existing `SteamHeadlessSession` / `SteamSessionHost` lifetime and shutdown path. No extra detached launcher, Wine server, or helper service is introduced. The separate Wine-child cleanup work can therefore cover D3DMetal launches through that same path.

### Offline DX12 verification

`Tests/Fixtures/d3d12-smoke.c` is an original, small Win32/D3D12 program, not a game download. It creates a D3D12 device, renders colored rectangles with render-target clears, presents a DXGI swapchain, waits for its GPU fence, copies the rendered texture to a readback heap, and verifies an orange pixel. The captured frame is real GPU output; it is not a simulated game screenshot.

The opt-in `GameGraphicsTests.offlineD3D12Sample` ran through **Pufflet's actual `SteamRuntime` environment**, with the pinned `wine-11.0-dxmt-2` runtime and the user-downloaded GPTK 4.0b2. The loaded module's PE `SizeOfImage=208896`, `TimeDateStamp=1783712738` matched Apple's `d3d12.dll`; the runtime's VKD3D DLL has different values (`94208`, `1790817215`). Device creation, present, fence and GPU pixel readback all passed. Apple framework loading was also recorded. This avoids mistaking mere framework initialization or a Wine fallback for D3DMetal rendering.

Reproduce (paths to Wine, Apple files and the compiler are deliberately supplied by the operator):

```sh
"$LLVM_MINGW_BIN/x86_64-w64-mingw32-clang" Tests/Fixtures/d3d12-smoke.c \
  -o /tmp/pufflet-d3d12-smoke.exe -ld3d12 -ldxgi -ldxguid -luuid -luser32 -Wall -Wextra -Werror
TEST_RUNNER_PUFFLET_D3DMETAL_RUNTIME="$RUNTIME_APP" \
TEST_RUNNER_PUFFLET_D3DMETAL_TOOLKIT="$GPTK_EVALUATION_ROOT" \
TEST_RUNNER_PUFFLET_D3DMETAL_SAMPLE=/tmp/pufflet-d3d12-smoke.exe \
TEST_RUNNER_PUFFLET_D3DMETAL_OUTPUT=/tmp/pufflet-d3dmetal-validation \
xcodebuild -project SteamLibrary.xcodeproj -scheme SteamLibrary \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build test \
  -only-testing:SteamLibraryTests/GameGraphicsTests/offlineD3D12Sample
```

The optional test creates only its own temporary prefix, soft-stops that prefix on completion/error, and uses the runtime's bounded teardown fallback. Ordinary tests skip it. If the selected runtime is under PuffletDev, acquire the Dev turn before inspecting/using it. The test does not sign in to Steam. No real Steam DX12 game or shader-heavy workload was claimed tested.

### Regression checks

- Full native suite: **95 tests in 20 suites passed**, using `xcodebuild -project SteamLibrary.xcodeproj -scheme SteamLibrary -destination 'platform=macOS,arch=arm64' -derivedDataPath build test-without-building` after a successful test build. LaunchServices conflicted with another registered worktree build during earlier attempts; the final already-built run passed.
- Opt-in graphics run: **6 tests passed**, including the real offline D3D12 sample and isolated native UI/detection screenshots.
- Site: **7 tests passed** with `node --experimental-strip-types --test site/tests/*.test.mjs`. Desktop and mobile guide rendering were inspected with the collaborative browser.
- `git diff --check` passed. No Apple binaries, compiled sample, raw environment logs, or account data are committed.

### Screenshots

- [Native first-run onboarding](images/d3dmetal/onboarding.png) — actual macOS window, isolated fixture with no account.
- [Native detected state](images/d3dmetal/toolkit-detected.png) — the same live UI after a complete directory fixture appears; file-layout detection is also exercised against the real Apple installation by the offline sample test.
- [D3D12 GPU frame readback](images/d3dmetal/d3d12-frame.png) — 800 × 500, captured by the sample after GPU completion.
- [Guide desktop](images/d3dmetal/guide-desktop.png) and [guide mobile](images/d3dmetal/guide-mobile.png) — browser captures of `/guides/game-porting-toolkit`, with no horizontal overflow at 390 CSS pixels and all four instructional screenshots loaded.

The guide's Apple public/sign-in screenshots and real Finder disk-image screenshots were captured with computer use. There is no signed-in download-list screenshot; that portion is explicitly described in text. No personal account details are present in published screenshots.

### Cleanup

The thread's temporary Wine prefixes were `/tmp/pufflet-dx12-check/prefix`, `/tmp/pufflet-dx12-check/prefix2`, and `/tmp/pufflet-d3dmetal-native-20261016/prefix`. Each was stopped; a scoped `ps` environment audit found **zero remaining processes** for these prefixes. Temporary test data remains for reproducibility, with no prefix left running. No production Pufflet data or real Steam library was used, and no runtime/GitHub release was published.
