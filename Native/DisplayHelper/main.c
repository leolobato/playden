#include "win32.h"

// Stdin: six little-endian int32 monitor coordinates, uint32 argc, then each argument as
// uint32 UTF-16 length followed by UTF-16LE data. No game arguments pass through cxstart parsing.
// Coordinates describe the Mac displays. Wine may scale all coordinates for Retina mode.
// The child receives the original arguments, workdir, DLL overrides and environment.
static MONITORINFOEXW monitors[32];
static int monitorCount;
static WCHAR executable[32768], commandLine[32768], argument[32768];
static DWORD commandLength;
static DWORD childPID;
static HWND candidate;
static long long candidateArea;
static RECT target;

static void message(const char *value) {
    DWORD count = 0, written = 0;
    while (value[count]) ++count;
    WriteFile(GetStdHandle((DWORD)-11), value, count, &written, 0);
}

#include "audio.h"

static BOOL enumerateMonitor(HMONITOR monitor, HDC dc, RECT *rect, LPARAM unused) {
    (void)dc; (void)rect; (void)unused;
    if (monitorCount >= 32) return 0;
    MONITORINFOEXW *info = &monitors[monitorCount];
    info->cbSize = sizeof(*info);
    if (!GetMonitorInfoW(monitor, info)) return 0;
    ++monitorCount;
    return 1;
}

static int near(int left, int right) { int delta = left - right; return delta >= -2 && delta <= 2; }

static BOOL chooseMonitor(const int *geometry) {
    int primary = -1;
    for (int i = 0; i < monitorCount; ++i) if (monitors[i].dwFlags & 1) primary = i;
    if (primary < 0) return 0;
    RECT origin = monitors[primary].rcMonitor;
    long long width = origin.right - origin.left, height = origin.bottom - origin.top;
    // Use independent axes to tolerate Windows DPI virtualization and rounding.
    RECT expected = {
        origin.left + (LONG)(geometry[0] * width / geometry[4]),
        origin.top + (LONG)(geometry[1] * height / geometry[5]),
        origin.left + (LONG)((geometry[0] + geometry[2]) * width / geometry[4]),
        origin.top + (LONG)((geometry[1] + geometry[3]) * height / geometry[5])
    };
    for (int i = 0; i < monitorCount; ++i) {
        RECT rect = monitors[i].rcMonitor;
        if (near(rect.left, expected.left) && near(rect.top, expected.top) &&
            near(rect.right, expected.right) && near(rect.bottom, expected.bottom)) {
            target = rect;
            return 1;
        }
    }
    // A display can disconnect between clicking Play and starting Windows. Keep playing.
    target = origin;
    message("[Big Screen display] Preferred display unavailable; using the main display.\n");
    return 1;
}

static BOOL enumerateWindow(HWND window, LPARAM unused) {
    (void)unused;
    if (!IsWindowVisible(window)) return 1;
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    // Holding the child process handle prevents PID reuse. Never touch another game/process.
    if (pid != childPID) return 1;
    RECT rect;
    if (!GetWindowRect(window, &rect)) return 1;
    int width = rect.right - rect.left, height = rect.bottom - rect.top;
    if (width < 64 || height < 64) return 1;
    long long area = (long long)width * height;
    if (area > candidateArea) { candidate = window; candidateArea = area; }
    return 1;
}

static BOOL placeWindow(void) {
    candidate = 0; candidateArea = 0;
    EnumWindows(enumerateWindow, 0);
    if (!candidate) return 0;
    RECT rect;
    if (!GetWindowRect(candidate, &rect)) return 0;
    int centerX = rect.left + (rect.right - rect.left) / 2;
    int centerY = rect.top + (rect.bottom - rect.top) / 2;
    if (centerX >= target.left && centerX < target.right && centerY >= target.top && centerY < target.bottom) return 1;
    MONITORINFOEXW current = {0}; current.cbSize = sizeof(current);
    if (!GetMonitorInfoW(MonitorFromWindow(candidate, 2), &current)) return 0;
    int width = rect.right - rect.left, height = rect.bottom - rect.top;
    BOOL fullscreen = !(GetWindowLongPtrW(candidate, -16) & 0x00c00000) &&
        width >= current.rcMonitor.right - current.rcMonitor.left &&
        height >= current.rcMonitor.bottom - current.rcMonitor.top;
    int targetWidth = target.right - target.left, targetHeight = target.bottom - target.top;
    if (fullscreen || width > targetWidth) width = targetWidth;
    if (fullscreen || height > targetHeight) height = targetHeight;
    int x = target.left + (targetWidth - width) / 2, y = target.top + (targetHeight - height) / 2;
    // Asynchronous: a game that is loading or not pumping messages cannot block this helper.
    // Preserve activation and Z order; Big Screen owns the foreground handoff.
    SetWindowPos(candidate, 0, x, y, width, height, 0x4000 | 0x0004 | 0x0010 | 0x0200);
    return 0;
}

static void placeStartupWindows(HANDLE process) {
    BOOL sawWindow = 0, placed = 0;
    int remaining = 100;
    message("[Big Screen display] Waiting for the game's first visible window.\n");
    // Cold starts can spend longer than ten seconds loading before creating a window.
    // Begin the movement budget at the first eligible child window, not CreateProcess.
    // Still stop after startup so a later monitor change by the player is respected.
    while (remaining > 0 && WaitForSingleObject(process, 100) != 0) {
        BOOL onTarget = placeWindow();
        if (candidate && !sawWindow) {
            sawWindow = 1;
            message("[Big Screen display] Game window appeared; applying the preferred display.\n");
        }
        if (sawWindow) --remaining;
        if (onTarget) {
            if (!placed) message("[Big Screen display] Game window reached the preferred display.\n");
            placed = 1;
        }
    }
    if (sawWindow && !placed) message("[Big Screen display] The game kept its own display setting.\n");
}

static BOOL readBytes(void *bytes, DWORD count) {
    unsigned char *destination = bytes;
    while (count) {
        DWORD size = 0;
        if (!ReadFile(GetStdHandle((DWORD)-10), destination, count, &size, 0) || !size) return 0;
        destination += size; count -= size;
    }
    return 1;
}

static void append(WCHAR value) {
    if (commandLength >= 32767) {
        message("[Big Screen display] Game arguments exceed the Windows command-line limit.\n"); ExitProcess(2);
    }
    commandLine[commandLength++] = value;
}

static BOOL readArguments(void) {
    DWORD count;
    if (!readBytes(&count, 4) || count < 1 || count > 1024) return 0;
    for (DWORD i = 0; i < count; ++i) {
        DWORD size;
        if (!readBytes(&size, 4) || size >= 32768 || !readBytes(argument, size * 2)) return 0;
        argument[size] = 0;
        for (DWORD j = 0; j < size; ++j) if (!argument[j]) return 0;
        if (i == 0) {
            if (!size) return 0;
            for (DWORD j = 0; j <= size; ++j) executable[j] = argument[j];
        } else { append(' '); }
        // Windows quoting: double backslashes before a quote and at the end of a quoted arg.
        append('"');
        DWORD slashes = 0;
        for (DWORD j = 0; j < size; ++j) {
            WCHAR value = argument[j];
            if (value == '\\') { ++slashes; continue; }
            DWORD escapeCount = value == '"' ? slashes * 2 + 1 : slashes;
            for (DWORD n = 0; n < escapeCount; ++n) append('\\');
            append(value); slashes = 0;
        }
        for (DWORD n = 0; n < slashes * 2; ++n) append('\\');
        append('"');
    }
    commandLine[commandLength] = 0;
    return 1;
}

void mainCRTStartup(void) {
    int geometry[6];
    if (!readBytes(geometry, sizeof(geometry))) ExitProcess(2);
    for (int i = 0; i < 6; ++i) if (geometry[i] < -131072 || geometry[i] > 131072) ExitProcess(2);
    BOOL hasDisplay = 0;
    for (int i = 0; i < 6; ++i) if (geometry[i]) hasDisplay = 1;
    if ((hasDisplay && (geometry[2] <= 0 || geometry[3] <= 0 || geometry[4] <= 0 || geometry[5] <= 0)) || !readArguments()) ExitProcess(2);
    configureAudio();
    BOOL canPlace = hasDisplay && EnumDisplayMonitors(0, 0, enumerateMonitor, 0) && chooseMonitor(geometry);
    if (hasDisplay && !canPlace) message("[Big Screen display] Display lookup unavailable; using the game's display.\n");
    STARTUPINFOW startup = {0}; startup.cb = sizeof(startup);
    if (canPlace) { startup.flags = 4; startup.x = target.left; startup.y = target.top; }
    PROCESS_INFORMATION child = {0};
    if (!CreateProcessW(executable, commandLine, 0, 0, 1, 0, 0, 0, &startup, &child)) {
        message("[Big Screen display] Could not start the game executable.\n"); ExitProcess(3);
    }
    CloseHandle(child.thread); childPID = child.pid;
    if (canPlace) placeStartupWindows(child.process);
    WaitForSingleObject(child.process, 0xffffffff);
    DWORD code = 1; GetExitCodeProcess(child.process, &code); CloseHandle(child.process);
    ExitProcess(code);
}
