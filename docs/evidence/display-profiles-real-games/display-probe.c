#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <stdio.h>
static BOOL CALLBACK window(HWND h, LPARAM ignored) {
    char title[256];
    GetWindowTextA(h, title, sizeof(title));
    if (!IsWindowVisible(h) || !title[0]) return TRUE;
    RECT c, r;
    GetClientRect(h, &c);
    GetWindowRect(h, &r);
    printf("window=%s client=%ldx%ld frame=%ldx%ld dpi=%u\n", title,
           c.right, c.bottom, r.right-r.left, r.bottom-r.top, GetDpiForWindow(h));
    return TRUE;
}
int main(void) {
    SetProcessDPIAware();
    DEVMODEW mode = {0};
    mode.dmSize = sizeof(mode);
    EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &mode);
    printf("desktop=%dx%d mode=%lux%lu dpi=%d\n", GetSystemMetrics(SM_CXSCREEN),
           GetSystemMetrics(SM_CYSCREEN), mode.dmPelsWidth, mode.dmPelsHeight,
           GetDeviceCaps(GetDC(NULL), LOGPIXELSX));
    EnumWindows(window, 0);
    return 0;
}
