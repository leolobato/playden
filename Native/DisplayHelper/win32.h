// Minimal x64 Windows ABI declarations. The helper uses OS DLLs and no C runtime.
#ifndef PLAYDEN_WIN32_H
#define PLAYDEN_WIN32_H
#if !defined(_WIN64)
#error Build this helper for 64-bit Windows.
#endif

typedef int BOOL;
typedef unsigned long DWORD;
typedef long LONG;
typedef unsigned short WCHAR;
typedef void *HANDLE;
typedef HANDLE HMONITOR;
typedef HANDLE HDC;
typedef HANDLE HWND;
typedef long long LPARAM;
typedef long long LONG_PTR;
typedef struct { LONG left, top, right, bottom; } RECT;
typedef struct { DWORD cbSize; RECT rcMonitor, rcWork; DWORD dwFlags; WCHAR szDevice[32]; } MONITORINFOEXW;
typedef struct {
    DWORD cb;
    WCHAR *reserved, *desktop, *title;
    DWORD x, y, width, height, xchars, ychars, fill, flags;
    unsigned short show, reservedSize;
    unsigned char *reservedBytes;
    HANDLE input, output, error;
} STARTUPINFOW;
typedef struct { HANDLE process, thread; DWORD pid, tid; } PROCESS_INFORMATION;
_Static_assert(sizeof(DWORD) == 4 && sizeof(RECT) == 16, "Windows scalar ABI");
_Static_assert(sizeof(STARTUPINFOW) == 104 && sizeof(PROCESS_INFORMATION) == 24, "Windows process ABI");
_Static_assert(sizeof(MONITORINFOEXW) == 104, "Windows monitor ABI");
#define IMPORT __declspec(dllimport)
IMPORT HANDLE GetStdHandle(DWORD);
IMPORT BOOL ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
IMPORT BOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
IMPORT void ExitProcess(unsigned int);
IMPORT WCHAR *GetCommandLineW(void);
IMPORT WCHAR **CommandLineToArgvW(const WCHAR *, int *);
IMPORT BOOL EnumDisplayMonitors(HDC, const RECT *, BOOL (*)(HMONITOR, HDC, RECT *, LPARAM), LPARAM);
IMPORT BOOL GetMonitorInfoW(HMONITOR, MONITORINFOEXW *);
IMPORT BOOL EnumWindows(BOOL (*)(HWND, LPARAM), LPARAM);
IMPORT BOOL IsWindowVisible(HWND);
IMPORT BOOL GetWindowRect(HWND, RECT *);
IMPORT DWORD GetWindowThreadProcessId(HWND, DWORD *);
IMPORT LONG_PTR GetWindowLongPtrW(HWND, int);
IMPORT BOOL SetWindowPos(HWND, HWND, int, int, int, int, unsigned int);
IMPORT HMONITOR MonitorFromWindow(HWND, DWORD);
IMPORT BOOL CreateProcessW(const WCHAR *, WCHAR *, void *, void *, BOOL, DWORD, void *, const WCHAR *, STARTUPINFOW *, PROCESS_INFORMATION *);
IMPORT DWORD WaitForSingleObject(HANDLE, DWORD);
IMPORT BOOL GetExitCodeProcess(HANDLE, DWORD *);
IMPORT BOOL CloseHandle(HANDLE);
#endif
