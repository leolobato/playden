// Deterministic Win32 boundary tests: no windows, focus changes, games or sleeps.
#include "win32.h"

static int polls, appearsAt, exitsAt, moves, rejectMove, resetAt;
static RECT gameRect;
static BOOL borderless;
static DWORD fixtureWait(HANDLE process, DWORD milliseconds);
static BOOL fixtureEnumWindows(BOOL (*callback)(HWND, LPARAM), LPARAM value);
static BOOL fixtureVisible(HWND window);
static BOOL fixtureRect(HWND window, RECT *rect);
static DWORD fixturePID(HWND window, DWORD *pid);
static LONG_PTR fixtureStyle(HWND window, int index);
static HMONITOR fixtureMonitor(HWND window, DWORD flags);
static BOOL fixtureMonitorInfo(HMONITOR monitor, MONITORINFOEXW *info);
static BOOL fixtureMove(HWND window, HWND after, int x, int y, int width, int height, unsigned int flags);

#define WaitForSingleObject fixtureWait
#define EnumWindows fixtureEnumWindows
#define IsWindowVisible fixtureVisible
#define GetWindowRect fixtureRect
#define GetWindowThreadProcessId fixturePID
#define GetWindowLongPtrW fixtureStyle
#define MonitorFromWindow fixtureMonitor
#define GetMonitorInfoW fixtureMonitorInfo
#define SetWindowPos fixtureMove
#define mainCRTStartup productionMainCRTStartup
#include "main.c"
#undef mainCRTStartup

static void check(BOOL condition, const char *failure) {
    if (!condition) { message(failure); ExitProcess(1); }
}
static DWORD fixtureWait(HANDLE process, DWORD milliseconds) {
    (void)process;
    check(milliseconds == 100, "Unexpected polling interval\n");
    ++polls;
    if (polls == resetAt) gameRect = (RECT){0, 0, 3008, 1692};
    return polls >= exitsAt ? 0 : 258;
}
static BOOL fixtureEnumWindows(BOOL (*callback)(HWND, LPARAM), LPARAM value) {
    callback((HWND)2, value); // Another process's large visible window must never count.
    callback((HWND)3, value); // The child has a hidden window while loading.
    callback((HWND)4, value); // And a visible but undersized utility window.
    if (polls >= appearsAt) callback((HWND)1, value);
    return 1;
}
static BOOL fixtureVisible(HWND window) { return window != (HWND)3; }
static BOOL fixtureRect(HWND window, RECT *rect) {
    *rect = window == (HWND)4 ? (RECT){0, 0, 30, 30} : gameRect;
    return 1;
}
static DWORD fixturePID(HWND window, DWORD *pid) { *pid = window == (HWND)2 ? 99 : 42; return 1; }
static LONG_PTR fixtureStyle(HWND window, int index) { (void)window; (void)index; return borderless ? 0 : 0x00c00000; }
static HMONITOR fixtureMonitor(HWND window, DWORD flags) { (void)window; (void)flags; return (HMONITOR)1; }
static BOOL fixtureMonitorInfo(HMONITOR monitor, MONITORINFOEXW *info) {
    (void)monitor; info->rcMonitor = (RECT){0, 0, 3008, 1692}; return 1;
}
static BOOL fixtureMove(HWND window, HWND after, int x, int y, int width, int height, unsigned int flags) {
    (void)after;
    check(window == (HWND)1, "Moved another process or utility window\n");
    check(flags == (0x4000 | 0x0004 | 0x0010 | 0x0200), "Changed foreground/Z-order behavior\n");
    ++moves;
    if (rejectMove) return 0;
    gameRect = (RECT){x, y, x + width, y + height}; return 1;
}
static void reset(int appearance, int exitPoll) {
    polls = moves = rejectMove = resetAt = 0;
    appearsAt = appearance; exitsAt = exitPoll;
    childPID = 42; target = (RECT){-1920, 0, 0, 1080};
    gameRect = (RECT){0, 0, 3008, 1692}; borderless = 1;
}
static BOOL fullscreenOnTarget(void) {
    return gameRect.left == -1920 && gameRect.top == 0 && gameRect.right == 0 && gameRect.bottom == 1080;
}
void mainCRTStartup(void) {
    reset(121, 1000); // Twelve seconds of loading used to exhaust the entire placement budget.
    placeStartupWindows((HANDLE)1);
    check(polls == 220 && moves == 1 && fullscreenOnTarget(), "Late fullscreen window was not placed\n");

    reset(321, 1000); // Unrelated/hidden/tiny windows must not start the countdown.
    placeStartupWindows((HANDLE)1);
    check(polls == 420 && moves == 1 && fullscreenOnTarget(), "Loading windows consumed the budget\n");

    reset(1, 1000); resetAt = 50; // An engine can reset its display during startup.
    placeStartupWindows((HANDLE)1);
    check(polls == 100 && moves == 2 && fullscreenOnTarget(), "Startup reset was not corrected\n");

    reset(1, 1000); rejectMove = 1;
    placeStartupWindows((HANDLE)1);
    check(polls == 100 && moves == 100, "A game rejecting movement was retried beyond startup\n");

    reset(1, 1000); borderless = 0; gameRect = (RECT){10, 10, 410, 310};
    placeStartupWindows((HANDLE)1);
    check(moves == 1 && gameRect.left == -1160 && gameRect.top == 390 &&
          gameRect.right == -760 && gameRect.bottom == 690, "Windowed size/centering changed\n");

    reset(1000, 35);
    placeStartupWindows((HANDLE)1);
    check(polls == 35 && moves == 0, "Windowless child exit did not stop observation\n");
    message("Passed: delayed windows, process isolation, startup reset, bounded retries, windowed size, and windowless exit.\n");
    ExitProcess(0);
}
