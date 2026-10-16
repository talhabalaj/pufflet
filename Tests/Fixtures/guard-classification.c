/* Test the shipped retry helper with one controlled Win32 API failure.
   This executable is a test fixture, never bundled in the app. */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

static unsigned queries;
static BOOL nongame;
static BOOL WINAPI image_query(HANDLE process, DWORD flags, WCHAR *path, DWORD *size)
{
    (void)process; (void)flags;
    if (++queries == 1) { SetLastError(ERROR_INVALID_HANDLE); return FALSE; }
    const WCHAR *image = nongame ? L"C:\\windows\\system32\\services.exe" : L"C:\\steamapps\\common\\Fixture\\game.exe";
    DWORD length = (DWORD)wcslen(image);
    if (*size <= length) return FALSE;
    memcpy(path, image, (length + 1) * sizeof(WCHAR)); *size = length;
    return TRUE;
}

#define QueryFullProcessImageNameW image_query
#define wmain unused_guard_main
#include "../../Runtime/WineProcessGuard.c"
#undef wmain
#undef QueryFullProcessImageNameW

int main(void)
{
    HANDLE retained = NULL;
    if (!DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(), GetCurrentProcess(), &retained, 0, FALSE, DUPLICATE_SAME_ACCESS)) return 1;
    struct tracked game = {.pid = GetCurrentProcessId(), .handle = retained};
    classify(&game);
    if (game.classified || game.game || queries != 1) return 2;
    classify(&game);
    if (!game.classified || !game.game || queries != 2) return 3;
    classify(&game);
    if (queries != 2) return 4;
    nongame = TRUE;
    struct tracked helper = {.pid = GetCurrentProcessId(), .handle = retained};
    classify(&helper);
    if (!helper.classified || helper.game || queries != 3) return 5;
    classify(&helper);
    if (queries != 3) return 6;
    CloseHandle(retained);
    puts("PASS: unknown image retried on retained handle; known game/non-game cached.");
    return 0;
}
