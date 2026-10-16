#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int n,char**v){
 if(n<4)return 2;
 HWND h=FindWindowA(NULL,v[1]);if(!h){puts("game window absent");return 3;}
 DWORD pid;GetWindowThreadProcessId(h,&pid);HANDLE p=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);char path[4096];DWORD len=sizeof(path);
 if(!p||!QueryFullProcessImageNameA(p,0,path,&len)){puts("identity unavailable");return 4;}CloseHandle(p);
 const char *relative=strstr(path,"\\steamapps\\common\\");
 if(_strnicmp(path,"C:\\SteamLibraries\\",18) || !relative ||
    (_stricmp(relative,"\\steamapps\\common\\Muck\\Muck.exe") &&
     _stricmp(relative,"\\steamapps\\common\\supercratebox\\supercratebox.exe") &&
     _stricmp(relative,"\\steamapps\\common\\over the hill\\over the hill.exe"))){puts("not a selected Dev test game");return 5;}
 SetForegroundWindow(h);Sleep(250);
 if(!strcmp(v[2],"key")) {
  BYTE key=(BYTE)strtoul(v[3],NULL,0);
  keybd_event(key,0,0,0);Sleep(250);keybd_event(key,0,KEYEVENTF_KEYUP,0);Sleep(250);
  printf("target=%s key=%u\n",path,key);return 0;
 }
 RECT r;GetClientRect(h,&r);POINT pt={(LONG)(r.right*atof(v[2])),(LONG)(r.bottom*atof(v[3]))};ClientToScreen(h,&pt);
 SetCursorPos(pt.x,pt.y);Sleep(200);mouse_event(MOUSEEVENTF_LEFTDOWN,0,0,0,0);Sleep(250);mouse_event(MOUSEEVENTF_LEFTUP,0,0,0,0);Sleep(300);
 printf("target=%s client=%ldx%ld point=%ld,%ld\n",path,r.right,r.bottom,pt.x,pt.y);return 0;
}
