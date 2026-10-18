/* Minimal Win32 declarations for the account-free native guard fixture. */
#include <stdint.h>
#include <wchar.h>
#include <wctype.h>
typedef void *HANDLE; typedef int BOOL; typedef unsigned DWORD; typedef unsigned long long ULONGLONG; typedef wchar_t WCHAR; typedef struct { DWORD dwLowDateTime, dwHighDateTime; } FILETIME;
#define TRUE 1
#define FALSE 0
#define WAIT_TIMEOUT 258
#define WAIT_OBJECT_0 0
#define ERROR_ALREADY_EXISTS 183
#define ERROR_NO_MORE_FILES 18
#define GENERIC_WRITE 1
#define CREATE_ALWAYS 1
#define FILE_ATTRIBUTE_NORMAL 0
#define INVALID_HANDLE_VALUE ((HANDLE)(intptr_t)-1)
#define SYNCHRONIZE 1
#define PROCESS_QUERY_LIMITED_INFORMATION 2
#define PROCESS_TERMINATE 4
#define DUPLICATE_SAME_ACCESS 1
BOOL QueryFullProcessImageNameW(HANDLE,DWORD,WCHAR*,DWORD*);
DWORD CharLowerBuffW(WCHAR*,DWORD);
DWORD WaitForSingleObject(HANDLE,DWORD);
HANDLE CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
BOOL CloseHandle(HANDLE);
HANDLE CreateEventW(void*,BOOL,BOOL,const WCHAR*);
HANDLE CreateMutexW(void*,BOOL,const WCHAR*);
DWORD GetLastError(void);
DWORD GetCurrentProcessId(void);
HANDLE GetCurrentProcess(void);
HANDLE OpenProcess(DWORD,BOOL,DWORD);
BOOL GetProcessTimes(HANDLE,FILETIME*,FILETIME*,FILETIME*,FILETIME*);
BOOL DuplicateHandle(HANDLE,HANDLE,HANDLE,HANDLE*,DWORD,BOOL,DWORD);
BOOL TerminateProcess(HANDLE,unsigned);
BOOL SetEvent(HANDLE);
void Sleep(DWORD);
