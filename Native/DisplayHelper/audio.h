// Wine's per-bottle output preference. The macOS default output is never changed.
// Core Audio UIDs map to endpoint GUIDs in winecoreaudio.drv's devices registry.
// Upstream: wine-mirror/wine, dlls/mmdevapi/devenum.c and dlls/winecoreaudio.drv/coreaudio.c.
typedef struct { DWORD data1; unsigned short data2, data3; unsigned char data4[8]; } AUDIO_GUID;
typedef struct AudioEnumerator AudioEnumerator;
typedef struct AudioEndpoint AudioEndpoint;
typedef struct {
    void *query, *addRef;
    DWORD (*release)(AudioEndpoint *);
    void *activate, *properties, *id;
    LONG (*state)(AudioEndpoint *, DWORD *);
} AudioEndpointTable;
struct AudioEndpoint { const AudioEndpointTable *table; };
typedef struct {
    void *query, *addRef;
    DWORD (*release)(AudioEnumerator *);
    void *enumerate, *defaultEndpoint;
    LONG (*getDevice)(AudioEnumerator *, const WCHAR *, AudioEndpoint **);
} AudioEnumeratorTable;
struct AudioEnumerator { const AudioEnumeratorTable *table; };
IMPORT DWORD GetEnvironmentVariableW(const WCHAR *, WCHAR *, DWORD);
IMPORT LONG CoInitializeEx(void *, DWORD);
IMPORT void CoUninitialize(void);
IMPORT LONG CoCreateInstance(const AUDIO_GUID *, void *, DWORD, const AUDIO_GUID *, void **);
IMPORT int StringFromGUID2(const AUDIO_GUID *, WCHAR *, int);
IMPORT LONG RegOpenKeyExW(HANDLE, const WCHAR *, DWORD, DWORD, HANDLE *);
IMPORT LONG RegCreateKeyExW(HANDLE, const WCHAR *, DWORD, WCHAR *, DWORD, DWORD, void *, HANDLE *, DWORD *);
IMPORT LONG RegQueryValueExW(HANDLE, const WCHAR *, DWORD *, DWORD *, unsigned char *, DWORD *);
IMPORT LONG RegSetValueExW(HANDLE, const WCHAR *, DWORD, DWORD, const unsigned char *, DWORD);
IMPORT LONG RegDeleteValueW(HANDLE, const WCHAR *);
IMPORT LONG RegCloseKey(HANDLE);
static const WCHAR audioDriverKey[] = L"Software\\Wine\\Drivers\\winecoreaudio.drv";
#define AUDIO_HKCU ((HANDLE)(LONG_PTR)(LONG)0x80000001)
static BOOL sameAudioString(const WCHAR *a, const WCHAR *b) {
    for (int i = 0; i < 256; ++i) { if (a[i] != b[i]) return 0; if (!a[i]) return 1; }
    return 0;
}
static BOOL readAudioString(HANDLE key, const WCHAR *name, WCHAR *value) {
    DWORD size = 512, type = 0;
    return RegQueryValueExW(key, name, 0, &type, (unsigned char *)value, &size) == 0 &&
        type == 1 && size >= 2 && size <= 512 && size % 2 == 0 && value[size / 2 - 1] == 0;
}
static void clearManagedAudio(void) {
    HANDLE key;
    if (RegOpenKeyExW(AUDIO_HKCU, audioDriverKey, 0, 0x2011f, &key)) return;
    WCHAR managed[256], current[256];
    if (readAudioString(key, L"BigScreenOutput", managed)) {
        // Do not remove a later override made directly in Wine's audio settings.
        if (readAudioString(key, L"DefaultOutput", current) && sameAudioString(managed, current)) {
            if (RegDeleteValueW(key, L"DefaultOutput"))
                message("[Playden audio] Could not restore the system-default output.\n");
        }
        RegDeleteValueW(key, L"BigScreenOutput");
    }
    RegCloseKey(key);
}
static BOOL selectAudioOutput(const WCHAR *uid) {
    static const AUDIO_GUID clsid = {0xbcde0395,0xe52f,0x467c,{0x8e,0x3d,0xc4,0x57,0x92,0x91,0x69,0x2e}};
    static const AUDIO_GUID iid = {0xa95664d2,0x9614,0x4f35,{0xa7,0x46,0xde,0x8d,0xb6,0x36,0x17,0xe6}};
    AudioEnumerator *enumerator = 0;
    // Creating the enumerator refreshes Wine's UID/GUID map, including newly connected devices.
    if (CoCreateInstance(&clsid, 0, 1, &iid, (void **)&enumerator) < 0) return 0;
    WCHAR keyName[512];
    static const WCHAR prefix[] = L"Software\\Wine\\Drivers\\winecoreaudio.drv\\devices\\0,";
    int length = 0;
    while (prefix[length]) { keyName[length] = prefix[length]; ++length; }
    for (int i = 0; uid[i]; ++i) {
        if (length >= 511 || uid[i] == '\\') { enumerator->table->release(enumerator); return 0; }
        keyName[length++] = uid[i];
    }
    keyName[length] = 0;
    HANDLE key;
    AUDIO_GUID guid;
    DWORD size = sizeof(guid), type = 0;
    BOOL found = 0;
    if (!RegOpenKeyExW(AUDIO_HKCU, keyName, 0, 0x20119, &key)) {
        found = !RegQueryValueExW(key, L"guid", 0, &type, (unsigned char *)&guid, &size) && type == 3 && size == sizeof(guid);
        RegCloseKey(key);
    }
    WCHAR endpointID[64] = L"{0.0.0.00000000}.";
    AudioEndpoint *endpoint = 0;
    DWORD state = 0;
    BOOL active = found && StringFromGUID2(&guid, endpointID + 17, 39) > 0 &&
        enumerator->table->getDevice(enumerator, endpointID, &endpoint) >= 0 &&
        endpoint->table->state(endpoint, &state) >= 0 && (state & 1);
    if (endpoint) endpoint->table->release(endpoint);
    enumerator->table->release(enumerator);
    if (!active) return 0;
    if (RegCreateKeyExW(AUDIO_HKCU, audioDriverKey, 0, 0, 0, 0x2011f, 0, &key, 0)) return 0;
    length = 0; while (endpointID[length]) ++length;
    size = (length + 1) * 2;
    BOOL written = !RegSetValueExW(key, L"BigScreenOutput", 0, 1, (const unsigned char *)endpointID, size) &&
                  !RegSetValueExW(key, L"DefaultOutput", 0, 1, (const unsigned char *)endpointID, size);
    RegCloseKey(key);
    return written;
}
static void configureAudio(void) {
    WCHAR uid[512];
    DWORD size = GetEnvironmentVariableW(L"PLAYDEN_AUDIO_DEVICE_UID", uid, 512);
    if (!size) { clearManagedAudio(); return; }
    LONG initialized = CoInitializeEx(0, 0);
    BOOL selected = initialized >= 0 && size < 512 && selectAudioOutput(uid);
    if (initialized >= 0) CoUninitialize();
    if (selected) message("[Playden audio] Preferred output selected for this game.\n");
    else {
        clearManagedAudio();
        message("[Playden audio] Preferred output unavailable; using the default output.\n");
    }
}
