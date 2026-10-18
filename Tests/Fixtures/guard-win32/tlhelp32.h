/* Minimal Win32 declarations for the account-free native guard fixture. */
#define TH32CS_SNAPPROCESS 1
typedef struct { unsigned dwSize; DWORD th32ProcessID, th32ParentProcessID; } PROCESSENTRY32W;
HANDLE CreateToolhelp32Snapshot(DWORD,DWORD);
BOOL Process32FirstW(HANDLE,PROCESSENTRY32W*);
BOOL Process32NextW(HANDLE,PROCESSENTRY32W*);
