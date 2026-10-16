# D3D12 through Apple's D3DMetal

Research checked 16 October 2026. This document separates the archived original Whisky from newer unrelated forks, and the current Apple download from historical GPTK releases. No Apple binaries are added to Pufflet's repository or runtime.

## Decision

Use a user-provided GPTK evaluation environment, preserving its complete `redist/lib` layout. Select graphics per game; keep DXMT as the existing D3D10/11 route. D3DMetal needs a Wine build with Apple's/CrossOver's integration patches, not merely a sufficiently high Wine version. Validate the exact Pufflet runtime rather than replace it just because its version is 11.

**Redistribution is conditionally permitted, not categorically prohibited.** The inspected GPTK 4.0 beta 2 license permits non-commercial redistribution and explicitly allows the Framework or Redistributables separately. It does not grant a general commercial distribution right. This implementation uses user installation/import, avoiding a claim about Pufflet's commercial status and retaining Apple's own license acceptance/download. This choice does not expand the user's rights under Apple's license.

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

A stock Wine 11 version string alone is **not** proof of compatibility. Pufflet uses Sikarugir11.0_1, whose actual shipped loader must be checked and tested. The public [Sikarugir Wine repository](https://github.com/Sikarugir-App/wine) master snapshot `455e3509b98a6919fd4ad1def4803e08c41c03b2` is tagged Wine 11.19 and is not necessarily the source of that older binary: do not infer its patches from today's master. The app must direct only the selected game's process tree to the Apple module directory, leaving DXMT/Steam defaults intact. Runtime/sample verification results are recorded with the implementation below rather than inferred from this research.

## CrossOver and Madeira

[CrossOver's official macOS user guide](https://media.codeweavers.com/pub/crossover/docs/en/userguide-crossover-mac-23.pdf) documents per-bottle D3DMetal and DXVK controls; D3DMetal supports D3D11/12. Apple's current package README explicitly names CrossOver as a prebuilt environment that incorporates its evaluation layers. It is an integrated, maintained Wine product, whereas original Whisky froze on the much older CrossOver 22.1.1/Wine 7.7 base.

[Madeira's own D3D12 notes](https://github.com/willfaust/Madeira/blob/main/madeira-d3d12/README.md) describe a separate native D3D12-to-Metal implementation using Apple's Metal Shader Converter, explicitly distinct from Apple's D3DMetal and not using its implementation. Its canary/cube milestones demonstrate that implementation's progress; they are not proof that arbitrary DX12 games work or a drop-in macOS GPTK installation strategy. Pufflet's Steam/Dock integration from Madeira is independent of the graphics backend decision.

## Verification

Implementation verification, exact commands, screenshots and remaining game limitations are added here after the runtime checks complete. No runtime or GitHub release is published as part of this work.
