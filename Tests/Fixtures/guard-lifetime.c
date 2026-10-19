/* Exercise the supervisor loop through synthetic Win32 process APIs.
   No Wine, user data, Steam account or application launch is involved. */
#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../Runtime/WineProcessGuard.c"

#define GAME L"C:\\steamapps\\common\\Fixture\\bin\\game.exe"
#define BOOT L"C:\\steamapps\\common\\Fixture\\bootstrap.exe"
#define HELPER L"C:\\steamapps\\common\\Fixture\\UnityCrashHandler64.exe"
#define UNKNOWN L"C:\\external\\worker.exe"
#define TOKEN(n) ((HANDLE)(uintptr_t)(n))

struct process {
    DWORD pid, parent, birth;
    int first, last, killed_at, query_fails_until, expected_kill;
    const WCHAR *path;
};
struct handle { struct process *process; BOOL closed; };
static struct process processes[4100];
static struct handle handles[50000];
static unsigned count, handle_count, scan;
static int tick, reverse, snapshot_fails_at = -1, enumeration_fails_at = -1;
static DWORD last_error;
static int open_fails_until, times_fail_until, duplicate_fails_until;
static DWORD failure_pid;
static jmp_buf done;

static BOOL alive(const struct process *process)
{
    return tick >= process->first && tick < process->last && process->killed_at < 0;
}
static void add(DWORD pid, DWORD parent, DWORD birth, int first, int last, const WCHAR *path, int expected_kill)
{
    assert(count < 4100);
    processes[count++] = (struct process){pid, parent, birth, first, last, -1, 0, expected_kill, path};
}
static HANDLE retain(struct process *process)
{
    assert(handle_count < 50000);
    handles[handle_count] = (struct handle){process, FALSE};
    return &handles[handle_count++];
}
static struct process *resolve(HANDLE value)
{
    struct handle *handle = value;
    assert(!handle->closed);
    return handle->process;
}
BOOL QueryFullProcessImageNameW(HANDLE value, DWORD flags, WCHAR *out, DWORD *size)
{
    struct process *process = resolve(value);
    if (tick < process->query_fails_until) return FALSE;
    assert(*size > wcslen(process->path));
    wcscpy(out, process->path);
    *size = (DWORD)wcslen(out);
    return TRUE;
}
DWORD CharLowerBuffW(WCHAR *path, DWORD size)
{
    for (DWORD i = 0; i < size; ++i) path[i] = towlower(path[i]);
    return size;
}
DWORD WaitForSingleObject(HANDLE value, DWORD milliseconds)
{
    return alive(resolve(value)) ? WAIT_TIMEOUT : WAIT_OBJECT_0;
}
HANDLE CreateFileW(const WCHAR *path, DWORD access, DWORD share, void *security, DWORD creation, DWORD attributes, HANDLE template)
{
    return TOKEN(20);
}
BOOL CloseHandle(HANDLE value)
{
    if ((uintptr_t)value < 100) return TRUE; /* Event, mutex, snapshot and ready file. */
    resolve(value);
    ((struct handle *)value)->closed = TRUE;
    return TRUE;
}
HANDLE CreateEventW(void *security, BOOL manual, BOOL initial, const WCHAR *name) { return TOKEN(21); }
HANDLE CreateMutexW(void *security, BOOL owner, const WCHAR *name) { return TOKEN(22); }
DWORD GetLastError(void) { return last_error; }
DWORD GetCurrentProcessId(void) { return 999; }
HANDLE GetCurrentProcess(void) { return TOKEN(23); }
HANDLE OpenProcess(DWORD access, BOOL inherit, DWORD pid)
{
    if (pid == failure_pid && tick < open_fails_until) return NULL;
    for (unsigned i = 0; i < count; ++i)
        if (processes[i].pid == pid && alive(&processes[i])) return retain(&processes[i]);
    return NULL;
}
BOOL GetProcessTimes(HANDLE value, FILETIME *created, FILETIME *exited, FILETIME *kernel, FILETIME *user)
{
    if (resolve(value)->pid == failure_pid && tick < times_fail_until) return FALSE;
    created->dwHighDateTime = 0;
    created->dwLowDateTime = resolve(value)->birth;
    return TRUE;
}
BOOL DuplicateHandle(HANDLE source, HANDLE value, HANDLE target, HANDLE *out, DWORD access, BOOL inherit, DWORD options)
{
    if (tick < duplicate_fails_until) return FALSE;
    *out = retain(resolve(value)); /* Distinct HANDLE, same retained process object. */
    return TRUE;
}
BOOL TerminateProcess(HANDLE value, unsigned code)
{
    struct process *process = resolve(value);
    if (alive(process)) process->killed_at = tick;
    return TRUE;
}
BOOL SetEvent(HANDLE value) { return TRUE; }
void Sleep(DWORD milliseconds)
{
    if (++tick == 5) longjmp(done, 1);
}
HANDLE CreateToolhelp32Snapshot(DWORD flags, DWORD pid)
{
    scan = 0;
    return tick == snapshot_fails_at ? INVALID_HANDLE_VALUE : TOKEN(24);
}
static BOOL next(PROCESSENTRY32W *out)
{
    while (scan < count) {
        unsigned i = reverse ? count - 1 - scan : scan;
        ++scan;
        if (alive(&processes[i])) {
            out->th32ProcessID = processes[i].pid;
            out->th32ParentProcessID = processes[i].parent;
            return TRUE;
        }
    }
    last_error = tick == enumeration_fails_at ? 5 : ERROR_NO_MORE_FILES;
    return FALSE;
}
BOOL Process32FirstW(HANDLE snapshot, PROCESSENTRY32W *out) { return next(out); }
BOOL Process32NextW(HANDLE snapshot, PROCESSENTRY32W *out) { return next(out); }

int main(int argc, char **argv)
{
    assert(argc == 2);
    const char *scenario = argv[1];
    if (!strcmp(scenario, "handoff") || !strcmp(scenario, "reverse")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 100, GAME, -1);
        reverse = !strcmp(scenario, "reverse");
    } else if (!strcmp(scenario, "handoff-helper")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 100, GAME, -1);
        add(3, 2, 21, 0, 100, HELPER, -1);
    } else if (!strcmp(scenario, "family-exit")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 2, GAME, -1);
        add(3, 2, 21, 0, 100, HELPER, 2);
        add(4, 100, 22, 0, 100, GAME, -1);
    } else if (!strcmp(scenario, "multiple")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 2, GAME, -1);
        add(3, 1, 21, 0, 3, GAME, -1);
        add(4, 2, 22, 0, 100, HELPER, 3);
    } else if (!strcmp(scenario, "nested")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 2, BOOT, -1);
        add(3, 2, 21, 0, 3, GAME, -1);
        add(4, 3, 22, 0, 100, HELPER, 3);
        reverse = TRUE;
    } else if (!strcmp(scenario, "unknown-image") || !strcmp(scenario, "query-retry")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 3, GAME, -1);
        add(3, 2, 21, 0, 100, HELPER, 3);
        processes[!strcmp(scenario, "unknown-image") ? 1 : 2].query_fails_until = 2;
    } else if (!strcmp(scenario, "late-bootstrap-classification")) {
        add(1, 100, 10, 0, 2, BOOT, -1);
        processes[0].query_fails_until = 1;
        add(2, 1, 20, 0, 3, GAME, -1);
        add(3, 1, 21, 0, 100, HELPER, 3);
    } else if (!strcmp(scenario, "unknown-worker")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 3, UNKNOWN, -1);
        add(3, 1, 21, 0, 100, HELPER, 3);
    } else if (!strcmp(scenario, "unrecognized-helper")) {
        add(1, 100, 10, 0, 1, GAME, -1);
        add(2, 1, 20, 0, 100, L"C:\\steamapps\\common\\Fixture\\unknown-helper.exe", -1);
        add(3, 1, 21, 0, 100, L"C:\\steamapps\\common\\Fixture\\unins000.exe", -1);
        add(4, 1, 22, 0, 100, L"C:\\steamapps\\common\\Fixture\\not-unitycrashhandler64.exe", -1);
    } else if (!strcmp(scenario, "cleanup")) {
        add(1, 100, 10, 0, 1, GAME, -1);
        add(2, 1, 20, 0, 100, HELPER, 1);
        add(3, 100, 21, 0, 100, GAME, -1);
        add(4, 100, 22, 0, 100, HELPER, -1); /* No observed game ancestry. */
    } else if (!strcmp(scenario, "pid-reuse")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 2, GAME, -1);
        add(3, 2, 21, 0, 100, HELPER, 2);
        add(1, 100, 30, 1, 100, GAME, -1);
    } else if (!strcmp(scenario, "missed-bootstrap")) {
        add(2, 1, 20, 0, 100, GAME, -1);
    } else if (!strcmp(scenario, "late-child")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 2, 100, GAME, -1);
    } else if (!strcmp(scenario, "failed-snapshot")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 100, HELPER, 2);
        snapshot_fails_at = 1;
    } else if (!strcmp(scenario, "failed-open") || !strcmp(scenario, "failed-times")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 1, 4, GAME, -1);
        add(3, 1, 21, 0, 100, HELPER, 4);
        failure_pid = 2;
        if (!strcmp(scenario, "failed-open")) open_fails_until = 2;
        else times_fail_until = 2;
    } else if (!strcmp(scenario, "failed-duplicate")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 4, GAME, -1);
        add(3, 1, 21, 0, 100, HELPER, 4);
        duplicate_fails_until = 2;
    } else if (!strcmp(scenario, "capacity")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 100, HELPER, -1);
        for (DWORD i = 0; i < 4095; ++i) add(1000 + i, 100, 30 + i, 0, 100, UNKNOWN, -1);
    } else if (!strcmp(scenario, "failed-enumeration")) {
        add(1, 100, 10, 0, 1, BOOT, -1);
        add(2, 1, 20, 0, 100, HELPER, 2);
        enumeration_fails_at = 1;
    } else {
        return 2;
    }
    WCHAR *args[] = {L"guard", L"ready"};
    if (!setjmp(done)) wmain(2, args);
    for (unsigned i = 0; i < count; ++i) {
        if (processes[i].killed_at != processes[i].expected_kill) {
            fprintf(stderr, "%s pid=%u birth=%u: expected termination tick %d, got %d\n",
                scenario, processes[i].pid, processes[i].birth, processes[i].expected_kill, processes[i].killed_at);
            return 1;
        }
    }
    printf("PASS: %s\n", scenario);
    return 0;
}
