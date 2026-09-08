#include "win32.h"
static void message(const char *value) {
    DWORD size = 0, written; while (value[size]) ++size;
    WriteFile(GetStdHandle((DWORD)-11), value, size, &written, 0);
}
#include "audio.h"
// Run as the helper's child: inspect the actual default endpoint selected by MMDevAPI.
void mainCRTStartup(void) {
    static const AUDIO_GUID clsid = {0xbcde0395,0xe52f,0x467c,{0x8e,0x3d,0xc4,0x57,0x92,0x91,0x69,0x2e}};
    static const AUDIO_GUID iid = {0xa95664d2,0x9614,0x4f35,{0xa7,0x46,0xde,0x8d,0xb6,0x36,0x17,0xe6}};
    if (CoInitializeEx(0, 0) < 0) ExitProcess(1);
    AudioEnumerator *enumerator = 0; AudioEndpoint *endpoint = 0; WCHAR *id = 0;
    if (CoCreateInstance(&clsid, 0, 1, &iid, (void **)&enumerator) < 0) ExitProcess(2);
    typedef LONG (*DefaultEndpoint)(AudioEnumerator *, int, int, AudioEndpoint **);
    typedef LONG (*EndpointID)(AudioEndpoint *, WCHAR **);
    if (((DefaultEndpoint)enumerator->table->defaultEndpoint)(enumerator, 0, 0, &endpoint) < 0 ||
        ((EndpointID)endpoint->table->id)(endpoint, &id) < 0) ExitProcess(3);
    message("BSAUDIO=");
    for (int i = 0; id[i]; ++i) { char value[2] = {(char)id[i], 0}; message(value); }
    message("\n");
    HANDLE key; WCHAR managed[256], current[256];
    if (!RegOpenKeyExW(AUDIO_HKCU, audioDriverKey, 0, 0x20119, &key)) {
        if (readAudioString(key, L"PlaydenOutput", managed)) {
            if (!readAudioString(key, L"DefaultOutput", current) ||
                !sameAudioString(managed, current) || !sameAudioString(managed, id)) ExitProcess(4);
            message("BSMANAGED=1\n");
        }
        RegCloseKey(key);
    }
    endpoint->table->release(endpoint); enumerator->table->release(enumerator);
    CoUninitialize(); ExitProcess(0);
}
