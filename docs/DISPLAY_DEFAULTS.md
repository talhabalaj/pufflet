# Standard display defaults

This first change ships Standard defaults only, as agreed during implementation.
The per-game Display picker and Sharp (Retina) option are deferred until the Wine
engine can implement them correctly. No game setting is offered that Wine ignores.

## Behavior and migration

Pufflet's private prefix defaults to Retina off and 96 DPI. Games use the display's
resolution in points, with macOS handling the backing scale. Automatic resolution
is unchanged; games retain their own fullscreen/windowed resolution settings.

Steam client setup no longer imports `RetinaMode=y` or `LogPixels=192`. On the next
private-prefix preparation or desktop-Steam launch, a separate migration imports
only these two values:

```reg
[HKEY_CURRENT_USER\Control Panel\Desktop]
"LogPixels"=dword:00000060
[HKEY_CURRENT_USER\Software\Wine\Mac Driver]
"RetinaMode"="n"
```

The prefix-local `.pufflet-standard-display-v1` marker is written only after a
successful import. Failed imports retry on the next launch. Later launches do not
rewrite display preferences. Other registry values, saves, installed games,
library links, and Steam account/session data are preserved. Desktop fallback does
not migrate an external wrapper's prefix. There are no new session restarts or
changes to Dock/session lifecycle. An already running game keeps its current
display configuration until it exits.

## Why AppDefaults cannot implement Sharp

[Wine 11's Mac driver](https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/winemac.drv/macdrv_main.c#L343-L346)
explicitly passes a null application key when reading `RetinaMode`. The comment
explains that DPI and monitor sizes must stay consistent across processes in a
prefix. [Sikarugir's source](https://github.com/Sikarugir-App/wine/blob/master/dlls/winemac.drv/macdrv_main.c)
retains this exclusion. Its other Mac driver options using AppDefaults do not make
RetinaMode an application setting.

The installed Wine 11.0 runtime was also checked in a separate test prefix:
global Retina off/96 DPI plus an application override requesting Retina still
produced a 1512×982 desktop after a cold start on this Mac. With global Retina on,
the driver desktop was 3024×1964. Thus an AppDefaults-only picker would be
ineffective. No supported per-launch Retina environment override was found.

A working Sharp implementation needs either an engine change with shared-display
compatibility testing, or separate prefixes with a larger Steam/session design.
Changing the shared registry between launches does not provide process isolation
and is unsuitable for a persistent session. Runtime artifacts and signing are
outside this PR. DPI remains 96; modern-game Sharp UI scaling is deferred with
Sharp. The optional virtual-desktop resolution selector is also deferred rather
than adding another launch mechanism in this Standard-only fix.

## Diagnostics

Each private-prefix preparation writes the queried registry configuration to
`wine.log`, using only numeric stage fields:

```text
[steam-host] pufflet1 display-defaults-migrated=1
[steam-host] pufflet1 display-mode=0
[steam-host] pufflet1 display-retina=0
[steam-host] pufflet1 display-dpi=96
[steam-host] pufflet1 display-resolution=0
```

`display-mode`: `0` Standard, `1` Retina, `2` custom DPI, `-1` unknown.
`display-retina`: `0` off, `1` on, `-1` unknown.
`display-dpi`: queried integer DPI, or `-1` if unavailable.
`display-resolution=0`: automatic, no virtual desktop override.
`display-defaults-migrated`: `1` only on the migration call, otherwise `0`.

These fields describe the registry configuration for new launches, not a running
game's chosen resolution or the cached display state of an existing process.
Raw query output, account identifiers, credentials, and filesystem paths are not
included in these lines.

## Validation

- The app builds with the normal Debug identity and signing disabled.
- Migration regression coverage checks once-only execution, save preservation,
  cleanup and retry after failed imports, and privacy-safe numeric diagnostics.
- The actual Swift migration helper was run against the isolated Wine prefix
  seeded with the old settings: first call migrated, second call skipped, and a
  test save was preserved.
- A standalone command-line harness ran the actual `SteamRuntime` registry-query
  and logging code against the same isolated prefix. It logged Standard, Retina
  off, DPI 96 and automatic resolution. A DPI-aware Windows probe independently
  reported DPI 96 and matching 1512×982 screen metrics/display mode.
- Wine display logging was enabled only in the isolated prefix
  (`WINEDEBUG=-all,+display,+macdrv`). The production prefix and Steam data were
  not used for these checks.
- Game visual evidence and normal-identity hosted test results are recorded below
  when verification is complete.
