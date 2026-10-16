/* Pufflet's prefix-local child supervisor. No Steam APIs or renderer assumptions. */
#include <windows.h>
#include <tlhelp32.h>
#include <wchar.h>

#define MAX_TRACKED 4096
struct tracked { DWORD pid, parent; HANDLE handle, root; BOOL game; ULONGLONG created; };
static struct tracked tracked[MAX_TRACKED];

static BOOL game_image(HANDLE process)
{
    WCHAR path[32768]; DWORD size = 32768;
    if (!QueryFullProcessImageNameW(process, 0, path, &size)) return FALSE;
    CharLowerBuffW(path, size);
    return wcsstr(path, L"\\steamapps\\common\\") && !wcsstr(path, L"crashhandler") && !wcsstr(path, L"unins");
}
static struct tracked *find(DWORD pid)
{
    for (unsigned i = 0; i < MAX_TRACKED; ++i)
        if (tracked[i].handle && tracked[i].pid == pid && WaitForSingleObject(tracked[i].handle, 0) == WAIT_TIMEOUT) return &tracked[i];
    return NULL;
}
static struct tracked *parent_of(const struct tracked *child)
{
    struct tracked *parent = NULL;
    for (unsigned i = 0; i < MAX_TRACKED; ++i)
        if (tracked[i].handle && tracked[i].pid == child->parent && tracked[i].created <= child->created &&
            (!parent || parent->created < tracked[i].created)) parent = &tracked[i];
    return parent;
}
static BOOL ready_file(const WCHAR *path)
{
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return FALSE;
    CloseHandle(file); return TRUE;
}
int wmain(int argc, WCHAR **argv)
{
    if (argc != 2) return 2;
    HANDLE event = CreateEventW(NULL, TRUE, FALSE, L"Local\\PuffletProcessGuardReadyV1");
    HANDLE mutex = CreateMutexW(NULL, TRUE, L"Local\\PuffletProcessGuardV1");
    if (!mutex || !event) return 3;
    if (GetLastError() == ERROR_ALREADY_EXISTS)
        return WaitForSingleObject(event, 10000) == WAIT_OBJECT_0 && ready_file(argv[1]) ? 0 : 4;
    BOOL announced = FALSE;
    for (;;) {
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        PROCESSENTRY32W item = {.dwSize = sizeof(item)};
        if (snapshot != INVALID_HANDLE_VALUE) {
            if (Process32FirstW(snapshot, &item)) do {
                if (item.th32ProcessID == GetCurrentProcessId() || find(item.th32ProcessID)) continue;
                HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE, FALSE, item.th32ProcessID);
                if (!process || WaitForSingleObject(process, 0) != WAIT_TIMEOUT) { if (process) CloseHandle(process); continue; }
                FILETIME created, exited, kernel, user;
                if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) { CloseHandle(process); continue; }
                ULONGLONG birth = ((ULONGLONG)created.dwHighDateTime << 32) | created.dwLowDateTime;
                for (unsigned i = 0; i < MAX_TRACKED; ++i) if (!tracked[i].handle) {
                    tracked[i] = (struct tracked){item.th32ProcessID, item.th32ParentProcessID, process, NULL, game_image(process), birth};
                    process = NULL; break;
                }
                if (process) CloseHandle(process);
            } while (Process32NextW(snapshot, &item));
            CloseHandle(snapshot);
        }
        /* Retain the root HANDLE too: both PID reuse and macOS reparenting
           are irrelevant to the Windows process relationship. */
        for (unsigned i = 0; i < MAX_TRACKED; ++i) if (tracked[i].handle && !tracked[i].root) {
            struct tracked *ancestor = &tracked[i], *root = NULL;
            for (unsigned depth = 0; ancestor && depth < 64; ++depth) {
                if (ancestor->game) root = ancestor;
                if (ancestor->root) {
                    DuplicateHandle(GetCurrentProcess(), ancestor->root, GetCurrentProcess(), &tracked[i].root, 0, FALSE, DUPLICATE_SAME_ACCESS);
                    break;
                }
                ancestor = parent_of(ancestor);
            }
            if (!tracked[i].root && root)
                DuplicateHandle(GetCurrentProcess(), root->handle, GetCurrentProcess(), &tracked[i].root, 0, FALSE, DUPLICATE_SAME_ACCESS);
        }
        for (unsigned i = 0; i < MAX_TRACKED; ++i) {
            struct tracked *child = &tracked[i];
            if (!child->handle) continue;
            if (child->root && WaitForSingleObject(child->root, 0) == WAIT_OBJECT_0)
                TerminateProcess(child->handle, 0); /* This game's retained descendants only. */
            if (WaitForSingleObject(child->handle, 0) == WAIT_OBJECT_0) {
                if (child->root) CloseHandle(child->root);
                CloseHandle(child->handle); child->handle = NULL; child->root = NULL;
            }
        }
        if (!announced) {
            if (!SetEvent(event) || !ready_file(argv[1])) return 5;
            announced = TRUE;
        }
        Sleep(50);
    }
}
