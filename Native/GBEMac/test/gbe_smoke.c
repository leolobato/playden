// Smoke test for the macOS gbe_fork libsteam_api.dylib.
//
// Usage: gbe_smoke <path/to/libsteam_api.dylib> <expected-appid> <expected-steamid> <expected-name> [--legacy-init]
//
// Loads the library the way a game does (dlopen + the flat C API, no Steam
// SDK headers), starts the Steam API, reads the account and the app ID, runs
// callbacks for a moment and shuts down. Exits 0 only if every value matches.
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef char SteamErrMsg[1024];
typedef int (*InitFlat_t)(SteamErrMsg *);   // ESteamAPIInitResult, 0 == OK
typedef bool (*Init_t)(void);
typedef bool (*RestartApp_t)(uint32_t);
typedef void (*Void_t)(void);
typedef void *(*Accessor_t)(void);
typedef uint64_t (*GetSteamID_t)(void *);
typedef uint32_t (*GetAppID_t)(void *);
typedef const char *(*GetPersonaName_t)(void *);
typedef bool (*IsLoggedOn_t)(void *);

static void *lib;
static int failures;

static void *sym(const char *name)
{
    void *p = dlsym(lib, name);
    if (!p) {
        fprintf(stderr, "FAIL missing symbol %s\n", name);
        exit(2);
    }
    return p;
}

static void check(bool ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "usage: %s <dylib> <appid> <steamid> <name> [--legacy-init]\n", argv[0]);
        return 64;
    }
    const char *path = argv[1];
    uint32_t want_appid = (uint32_t)strtoul(argv[2], NULL, 10);
    uint64_t want_steamid = strtoull(argv[3], NULL, 10);
    const char *want_name = argv[4];
    bool legacy = argc > 5 && strcmp(argv[5], "--legacy-init") == 0;

#if defined(__arm64__)
    printf("arch arm64\n");
#elif defined(__x86_64__)
    printf("arch x86_64\n");
#endif

    lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        fprintf(stderr, "FAIL dlopen: %s\n", dlerror());
        return 2;
    }
    check(true, "dlopen");

    // A game calls this first; without a Steam client gbe_fork must say "no restart".
    bool restart = ((RestartApp_t)sym("SteamAPI_RestartAppIfNecessary"))(want_appid);
    check(!restart, "SteamAPI_RestartAppIfNecessary returns false");

    if (legacy) {
        bool ok = ((Init_t)sym("SteamAPI_Init"))();
        check(ok, "SteamAPI_Init");
        if (!ok) return 1;
    } else {
        SteamErrMsg err = {0};
        int res = ((InitFlat_t)sym("SteamAPI_InitFlat"))(&err);
        printf("     SteamAPI_InitFlat -> %d '%s'\n", res, err);
        check(res == 0, "SteamAPI_InitFlat == k_ESteamAPIInitResult_OK");
        if (res != 0) return 1;
    }

    void *user = ((Accessor_t)sym("SteamAPI_SteamUser_v023"))();
    check(user != NULL, "SteamAPI_SteamUser_v023");
    uint64_t steamid = ((GetSteamID_t)sym("SteamAPI_ISteamUser_GetSteamID"))(user);
    printf("     steam id %llu\n", (unsigned long long)steamid);
    check(steamid == want_steamid, "SteamAPI_ISteamUser_GetSteamID matches configs.user.ini");
    check(((IsLoggedOn_t)sym("SteamAPI_ISteamUser_BLoggedOn"))(user), "SteamAPI_ISteamUser_BLoggedOn");

    void *utils = ((Accessor_t)sym("SteamAPI_SteamUtils_v010"))();
    check(utils != NULL, "SteamAPI_SteamUtils_v010");
    uint32_t appid = ((GetAppID_t)sym("SteamAPI_ISteamUtils_GetAppID"))(utils);
    printf("     app id %u\n", appid);
    check(appid == want_appid, "SteamAPI_ISteamUtils_GetAppID matches steam_appid.txt");

    void *friends = ((Accessor_t)sym("SteamAPI_SteamFriends_v017"))();
    check(friends != NULL, "SteamAPI_SteamFriends_v017");
    const char *name = ((GetPersonaName_t)sym("SteamAPI_ISteamFriends_GetPersonaName"))(friends);
    printf("     persona '%s'\n", name ? name : "(null)");
    check(name && strcmp(name, want_name) == 0, "SteamAPI_ISteamFriends_GetPersonaName matches configs.user.ini");

    Void_t run = (Void_t)sym("SteamAPI_RunCallbacks");
    for (int i = 0; i < 20; i++) {
        run();
        usleep(50 * 1000);
    }
    check(true, "SteamAPI_RunCallbacks x20 over 1s");

    ((Void_t)sym("SteamAPI_Shutdown"))();
    check(true, "SteamAPI_Shutdown");

    printf("%s (%d failure%s)\n", failures ? "FAILED" : "PASSED", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
