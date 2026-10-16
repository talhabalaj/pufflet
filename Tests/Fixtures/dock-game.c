#include <windows.h>
#include <stdio.h>
#include <string.h>

/* Offline Wine fixture: record the native Quit handshake without Steam. */
static const char *marker;
static void record(const char *suffix)
{
    char path[32768];
    snprintf(path, sizeof(path), "%s.%s", marker, suffix);
    HANDLE file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_QUERYENDSESSION) { record("query"); return TRUE; }
    if (message == WM_ENDSESSION && wparam) record("end");
    if (message == WM_TIMER) { DestroyWindow(window); return 0; }
    if (message == WM_DESTROY) PostQuitMessage(0);
    return DefWindowProcA(window, message, wparam, lparam);
}

int main(int argc, char **argv)
{
    if (argc != 3) return 2;
    marker = argv[2];
    if (!strcmp(argv[1], "companion")) {
        record("ready");
        Sleep(INFINITE);
        return 0;
    }
    if (!strncmp(argv[1], "game", 4)) {
        char image[32768], command[32768];
        GetModuleFileNameA(NULL, image, sizeof(image));
        char *slash = strrchr(image, '\\');
        if (!slash) return 5;
        strcpy(slash + 1, "UnityCrashHandler64.exe");
        snprintf(command, sizeof(command), "\"%s\" helper \"%s.child\"", image, marker);
        STARTUPINFOA startup = {.cb = sizeof(startup)}; PROCESS_INFORMATION child;
        if (!CreateProcessA(image, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child)) return 6;
        CloseHandle(child.hProcess); CloseHandle(child.hThread);
    }
    WNDCLASSA type = {0};
    type.lpfnWndProc = window_proc;
    type.hInstance = GetModuleHandleA(NULL);
    type.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    type.lpszClassName = "PuffletDockFixture";
    if (!RegisterClassA(&type)) return 3;
    HWND window = CreateWindowA(type.lpszClassName, "Pufflet Dock Test", WS_OVERLAPPEDWINDOW,
                               120, 120, 540, 300, NULL, NULL, type.hInstance, NULL);
    if (!window) return 4;
    ShowWindow(window, SW_SHOW);
    if (!strcmp(argv[1], "game-exit")) SetTimer(window, 1, 3000, NULL);
    record("ready");
    MSG message;
    while (GetMessageA(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageA(&message);
    }
    return 0;
}
