/* Pufflet's prefix-local child supervisor. No Steam APIs or renderer assumptions. */
#include <windows.h>
#include <tlhelp32.h>
#include <wchar.h>

#define MAX_TRACKED 4096
struct tracked {
    DWORD pid, parent;
    HANDLE handle, root;
    BOOL game, classified;
    ULONGLONG created;
    BOOL helper;
    DWORD root_pid;
    ULONGLONG root_created;
};
static struct tracked tracked[MAX_TRACKED];

static BOOL game_image(HANDLE process, BOOL *classified, BOOL *helper)
{
    WCHAR path[32768]; DWORD size = 32768;
    if (!QueryFullProcessImageNameW(process, 0, path, &size)) return FALSE;
    *classified = TRUE;
    CharLowerBuffW(path, size);
    const WCHAR *name = wcsrchr(path, L'\\');
    name = name ? name + 1 : path;
    /* Only known crash reporters are safe to reap automatically. A path
       outside the game directory (or an image-query failure) is not proof. */
    *helper = !wcscmp(name, L"unitycrashhandler32.exe") || !wcscmp(name, L"unitycrashhandler64.exe");
    return wcsstr(path, L"\\steamapps\\common\\") && !wcsstr(path, L"crashhandler") && !wcsstr(path, L"unins");
}
static void classify(struct tracked *process)
{
    /* A failed query is unknown, not a permanent non-game decision. Keep
       retrying the same retained live handle; successful decisions are cached. */
    if (!process->classified && WaitForSingleObject(process->handle, 0) == WAIT_TIMEOUT)
        process->game = game_image(process->handle, &process->classified, &process->helper);
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
static BOOL retain_root(struct tracked *child, const struct tracked *ancestor)
{
    HANDLE root = ancestor->root ? ancestor->root : ancestor->handle;
    DWORD pid = ancestor->root ? ancestor->root_pid : ancestor->pid;
    ULONGLONG created = ancestor->root ? ancestor->root_created : ancestor->created;
    if (DuplicateHandle(GetCurrentProcess(), root, GetCurrentProcess(), &child->root, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
        child->root_pid = pid;
        child->root_created = created;
        return TRUE;
    }
    return FALSE;
}
static BOOL family_active(const struct tracked *child)
{
    /* Duplicated HANDLE values differ. Use the retained root's identity even
       after its tracked slot is reclaimed; a reused PID is a different family.
       Unknown and unrecognized images conservatively count as gameplay. */
    for (unsigned i = 0; i < MAX_TRACKED; ++i) {
        const struct tracked *member = &tracked[i];
        if (member->handle && member->root && !member->helper &&
            member->root_pid == child->root_pid && member->root_created == child->root_created &&
            WaitForSingleObject(member->handle, 0) != WAIT_OBJECT_0) return TRUE;
    }
    return FALSE;
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
    BOOL announced = FALSE, exhausted = FALSE;
    for (;;) {
        for (unsigned i = 0; i < MAX_TRACKED; ++i)
            if (tracked[i].handle) classify(&tracked[i]);
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        BOOL complete = snapshot != INVALID_HANDLE_VALUE;
        PROCESSENTRY32W item = {.dwSize = sizeof(item)};
        if (snapshot != INVALID_HANDLE_VALUE) {
            if (Process32FirstW(snapshot, &item)) do {
                if (item.th32ProcessID == GetCurrentProcessId() || find(item.th32ProcessID)) continue;
                HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE, FALSE, item.th32ProcessID);
                if (!process) { complete = FALSE; continue; }
                DWORD state = WaitForSingleObject(process, 0);
                if (state != WAIT_TIMEOUT) {
                    if (state != WAIT_OBJECT_0) complete = FALSE;
                    CloseHandle(process); continue;
                }
                FILETIME created, exited, kernel, user;
                if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) { complete = FALSE; CloseHandle(process); continue; }
                ULONGLONG birth = ((ULONGLONG)created.dwHighDateTime << 32) | created.dwLowDateTime;
                for (unsigned i = 0; i < MAX_TRACKED; ++i) if (!tracked[i].handle) {
                    tracked[i] = (struct tracked){.pid = item.th32ProcessID, .parent = item.th32ParentProcessID,
                        .handle = process, .created = birth};
                    classify(&tracked[i]);
                    process = NULL; break;
                }
                if (process) { complete = FALSE; exhausted = TRUE; CloseHandle(process); }
            } while (Process32NextW(snapshot, &item));
            if (GetLastError() != ERROR_NO_MORE_FILES) complete = FALSE;
            CloseHandle(snapshot);
        }
        /* Retain the root HANDLE and identity. A launcher and its gameplay
           descendants share a family, whose lifetime can outlast the launcher. */
        for (unsigned i = 0; i < MAX_TRACKED; ++i) if (tracked[i].handle && !tracked[i].root) {
            struct tracked *ancestor = &tracked[i], *root = NULL;
            for (unsigned depth = 0; ancestor && depth < 64; ++depth) {
                /* A launcher whose image is temporarily unreadable must still
                   connect its children. Otherwise a later successful query
                   could split one handoff into independently reaped families. */
                if (ancestor->game || !ancestor->classified) root = ancestor;
                if (ancestor->root) {
                    if (!retain_root(&tracked[i], ancestor)) complete = FALSE;
                    break;
                }
                ancestor = parent_of(ancestor);
            }
            if (!tracked[i].root && root)
                if (!retain_root(&tracked[i], root)) complete = FALSE;
        }
        for (unsigned i = 0; i < MAX_TRACKED; ++i) {
            struct tracked *child = &tracked[i];
            if (!child->handle) continue;
            if (complete && !exhausted && child->helper && child->root &&
                WaitForSingleObject(child->root, 0) == WAIT_OBJECT_0 && !family_active(child))
                TerminateProcess(child->handle, 0); /* Identified crash helpers after gameplay ends only. */
            /* Preserve exited ancestors until observation recovers, so a retry
               can still connect a newly observed gameplay child to its family.
               At capacity we must reclaim slots, but disable automatic reaping
               for this guard session because ancestry may have been lost. */
            if ((complete || exhausted) && WaitForSingleObject(child->handle, 0) == WAIT_OBJECT_0) {
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
