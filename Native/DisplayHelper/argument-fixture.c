#include "win32.h"
static void bytes(const void *data,DWORD count) { DWORD written;WriteFile(GetStdHandle((DWORD)-11),data,count,&written,0); }
void mainCRTStartup(void) {
    int argc=0;WCHAR **argv=CommandLineToArgvW(GetCommandLineW(),&argc);
    bytes("BSCARGS",7);bytes(&argc,4);
    for(int i=0;i<argc;i++){DWORD length=0;while(argv[i][length])length++;bytes(&length,4);bytes(argv[i],length*2);}
    ExitProcess(37);
}
