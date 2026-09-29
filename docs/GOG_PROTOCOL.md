# GOG protocol

The wire protocol that `Packages/GOGKit` implements. Requirements are in [PRD 10](prd/10-gog.md).

Research date: 2026-09-29. The sections after "Spike results" are the source research. Where they
say **UNCONFIRMED**, check "Spike results" first: it records what a signed-in account showed.

## Spike results (2026-09-29, real account)

Run with `gog-dev` (`Packages/GOGKit`) against a library of 27 products.

- **The redirect address is fixed.** A login URL with `redirect_uri=http://127.0.0.1:47831/gog`
  stops on the login page with `{"error":"redirect_uri_mismatch","error_description":"The redirect
  URI provided does not match registered URI(s)."}`. Only `embed.gog.com/on_login_success?origin=client`
  works, so the phone relay needs the paste step.
- **Tokens:** `expires_in` is 3600. Six refreshes in a row returned the same refresh token (no
  rotation seen); Playden still stores whatever comes back.
- **Library:** `embed.gog.com/user/data/games` listed 27 IDs, and `galaxy-library` listed 26 (all
  `platform_id == gog`). gamesdb typed 23 as `game` (all `visible_in_library`) and 4 as `spam`
  (packs, a duplicate Fallout ID, "Galaxy CDN traffic"). The embed list plus the gamesdb filter is
  enough.
- **Builds:** every game had a default-branch build (`branch == null`) first. 22 Windows games were
  gen 2 and one (Monkey Island 2 Special Edition) was gen 1 only. All 14 Mac builds were gen 2.
- **CDN order:** `fastly` has `priority 10` and `gcore` has `priority 1, fallback_only true`.
  A higher priority wins.
- **Secure links** (the same shape for gen 1 and gen 2):
  - `fastly`: `url_format` `{base_url}/token=nva={expires_at}~dirs={dirs}~token={token}{path}`, with
    `path` `/content-system/v2/store/<product>` (gen 2) or `/content-system/v1/depots/<product>/<os>/<timestamp>` (gen 1).
  - `gcore`: `url_format` `{base_url}/{path}?wsSecret={token}&wsTime={time}&prefix={prefix}`, with
    `path` without the leading `/`.
  - `expires_at` is 24 hours after the request. A download still re-fetches on 401/403.
  - Chunk URLs append `/ab/cd/<compressedMd5>` to `path`; gen 1 appends `/main.bin` and a `Range`
    request returns 206 with the file's bytes (MD5 matched).
- **Launch tasks:** paths are relative to the install root, with `/` separators in the info file.
  - Windows gen 2: `VirtuaVerse.exe` (primary, `category launcher`) and a hidden
    `VirtuaVerse/VirtuaVerse.exe` (`category game`).
  - Windows gen 1: `monkey2.exe` with an empty `workingDir`, and a second task `language_setup.exe`.
  - macOS gen 2: `Contents/MacOS/VirtuaVerse`, `Contents/MacOS/BnC_GOG`, and for ScummVM and DOSBox
    games a wrapper, `Contents/MacOS/GOGLauncher` or `Contents/MacOS/Launcher`. A `URLTask` (a
    support link) can follow.
- **macOS layout:** the install root **is** the app bundle: `Contents/Info.plist`,
  `Contents/MacOS/<exe>`, with `goggame-<id>.info` and `.hashdb` in `Contents/Resources`. Playden
  must name the install folder `<name>.app`. (Prison Architect's layout in §7 is the exception seen
  in the research.)
- **Signatures:** of three Mac builds, one was unsigned (Flashback, x86_64), and two had ad-hoc
  signatures whose seal no longer matches, because GOG adds files after signing (VirtuaVerse,
  arm64: the `goggame` files, `libGalaxy.dylib`; Tyrian 2000, x86_64: "invalid Info.plist").
  All three start, both by running the executable and through LaunchServices (`open`, as
  `NativeRunner` does), with no re-signing. The DOSBox wrapper starts its own `dosbox` from
  `Contents/Resources`.
- **Architectures:** VirtuaVerse is arm64; Flashback and Tyrian 2000 are x86_64 (Rosetta).
- **Not seen in this library:** a gen 1 Mac build, and a non-owner's secure-link answer.
- **Support files and install scripts** (found in acceptance, 2026-09-30): support files under
  `app/` belong in the game folder (DOSBox configs). Windows builds carry `goggame-<id>.script`,
  JSON `actions` with `install.action` of `supportData` (copy `{supportDir}/…` to `{app}`, or
  create a folder), `setIni` (`filename`, `section`, `keyName`, `keyValue`, `utf8`) and
  `setRegistry` (`root`, `subkey`, `valueName`, `valueData`, `valueType`). Variables:
  `{app}`, `{supportDir}`, `{productID}`. ScummVM games need `setIni` to write the game `path`.

## Sources read (commit SHAs)

| Project | Repo | Commit | Date |
|---|---|---|---|
| gogdl (GPL-3) | github.com/Heroic-Games-Launcher/heroic-gogdl `main` | `9c593fdba2a3e829a48e45e6475d8db937833dce` | 2026-09-08 |
| Heroic (TS frontend/backend) | github.com/Heroic-Games-Launcher/HeroicGamesLauncher `main` | `3934a83a0707baad23cd2c06bc94bd23f51e6622` | 2026-09-19 |
| lgogdownloader (WTFPL) | github.com/Sude-/lgogdownloader | `bb80e164dccfb72485932725b618ffa66854e7c4` | 2026-09-13 |
| minigalaxy (GPL-3) | github.com/sharkwouter/minigalaxy | `242e4ee5ef29870e5f908de8e498b51d254bf261` | 2026-09-23 |

Tags used below:
- `[gogdl path:line]`: path is relative to the gogdl repo `gogdl/` package. For example, `dl/managers/v2.py:161` means `gogdl/dl/managers/v2.py`.
- `[heroic path:line]`: path is relative to Heroic `src/`.
- `[lgog path:line]` and `[minigalaxy path:line]`: path is relative to that repo's root.
- `[live]`: I checked this with an unauthenticated curl/python request on 2026-09-29. The test product was Prison Architect `1441974651`, plus some old games for the gen1 check.
- **UNCONFIRMED**: the source code does not show it and I could not test it. Most of these items need an authenticated session.

Base constants [gogdl constants.py:4-11]:
```
GOG_CDN            = https://gog-cdn-fastly.gog.com
GOG_CONTENT_SYSTEM = https://content-system.gog.com
GOG_EMBED          = https://embed.gog.com
GOG_AUTH           = https://auth.gog.com
GOG_API            = https://api.gog.com
GOG_CLOUDSTORAGE   = https://cloudstorage.gog.com
DEPENDENCIES_URL   = https://content-system.gog.com/dependencies/repository?generation=2
DEPENDENCIES_V1_URL= https://content-system.gog.com/redists/repository
```
lgogdownloader uses `https://cdn.gog.com/content-system/...` for manifests [lgog src/galaxyapi.cpp:199,216-218]. Builds responses with `_version=2` list two CDNs: `gog-cdn-fastly.gog.com` (endpoint_name `fastly`) and `gog-cdn.gcdn.co` (endpoint_name `gcore`) [live].

---

## 1. Auth

### Client credentials (the "Galaxy client")
- `client_id = 46899977096215655`
- `client_secret = 9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9`
- Sources: [gogdl auth.py:12-13], [lgog include/config.h:206-209], [minigalaxy minigalaxy/api.py:29-30]. All four clients use the same pair.

### Authorization URL (needs a browser or webview)
Heroic [heroic frontend/screens/WebView/index.tsx:87-88]:
```
https://auth.gog.com/auth?client_id=46899977096215655
  &redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient
  &response_type=code
  &layout=galaxy
```
- Other `layout` values in use:
  - `layout=client2` [minigalaxy api.py:194-201]
  - `layout=default&brand=gog` [lgog src/website.cpp:356]
- The `layout` value only changes the look of the page. **UNCONFIRMED** that it has any other effect.
- `auth.gog.com/auth` returns `302` to `https://login.gog.com/auth?...` with the same params [live].
- Getting the code: watch the webview navigation. When the URL matches `https://embed.gog.com/on_login_success?`, read the `code` query param. Sources: [heroic WebView/index.tsx:86,204-212] and [minigalaxy minigalaxy/ui/login.py:33-38,68-72]. lgogdownloader uses the regex `.*code=(.*?)([?&].*|$)` on the pasted URL [lgog src/website.cpp:584,620].

### Is `redirect_uri` fixed per client id?
- **UNCONFIRMED.** All four clients hardcode `https://embed.gog.com/on_login_success?origin=client`.
- `auth.gog.com/auth` returned 302 to `login.gog.com` for every value I tried: the real value, the value without `?origin=client`, `http://localhost:8080/cb`, and `playden://auth` [live]. The redirect is **not** evidence that GOG accepts these values. GOG probably checks the value after login or at token exchange, and I could not test either without credentials.
- The token endpoint checks that the code belongs to the client. A bogus code returns `400 {"error":"invalid_grant","error_description":"Code doesn't exist or is invalid for the client"}` [live].
- Plan for a WKWebView that intercepts `embed.gog.com/on_login_success`, exactly as Heroic and minigalaxy do.

### Token exchange (authorization_code)
All clients send an HTTP **GET** with query params:
```
GET https://auth.gog.com/token?client_id=46899977096215655
   &client_secret=9d85c43b...46d9
   &grant_type=authorization_code
   &redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient
   &code=<code>
```
- Sources: [gogdl auth.py:11,125], [lgog src/website.cpp:318-321], [minigalaxy api.py:57-70].
- The `redirect_uri` must equal the one used on `/auth`.
- Response fields, from the `GOGCredentials` type [heroic common/types/gog.ts:509-518]: `access_token`, `expires_in`, `token_type`, `scope`, `session_id`, `refresh_token`, `user_id`, `loginType`.
- gogdl adds a local `loginTime` field (unix seconds) and saves the result under the key `client_id` [gogdl auth.py:135-139].
- Failure: `{"error": "...", "error_description": "..."}` with a 4xx status [live].

### Refresh (refresh_token grant)
```
GET https://auth.gog.com/token?client_id=<id>&client_secret=<secret>
   &grant_type=refresh_token&refresh_token=<refresh_token>[&without_new_session=1]
```
Sources: [gogdl auth.py:102-105], [lgog src/galaxyapi.cpp:59-63], [minigalaxy api.py:46-54].

### Token lifetime
- The server returns `expires_in`. lgogdownloader uses 3600 s when the field is missing [lgog include/config.h:118-126]. The live value is **UNCONFIRMED**; 3600 is the community value.
- gogdl treats a token as expired when `time.time() >= loginTime + expires_in`, with no safety margin [gogdl auth.py:81]. It then refreshes on demand [gogdl auth.py:60-64, api.py:76-80].
- The refresh response replaces the old token set. Whether GOG rotates the refresh token is **UNCONFIRMED**, so always store the new `refresh_token`.

### Per-product ("game") credentials
- Every v2 build meta has a `clientId` and a `clientSecret` for that game [live]. For Prison Architect: `clientId=48384666369469807`.
- gogdl reads these values from `builds.items[0].link` → meta [gogdl saves.py:243-251].
- gogdl gets a game token with the **refresh_token grant**, using the **main Galaxy client's refresh_token**, the game's `client_id` and `client_secret`, and `&without_new_session=1` [gogdl auth.py:91-105; get_credentials path at auth.py:53-58].
- The game token is only needed for **cloudstorage** (saves) [gogdl saves.py:201-205]. Heroic also uses the `clientId` (without a token) for remote-config [heroic backend/storeManagers/gog/library.ts:294].
- Downloads, builds, secure links and the library all use the main Galaxy token.
- lgogdownloader follows the same pattern: `refreshLogin(..., newSession=false)` adds `without_new_session=1` [lgog galaxyapi.cpp:57-63].

### Device flow or no-browser login
- None of the four codebases has a device or code flow. Whether GOG offers one is **UNCONFIRMED** (nothing found).
- The only way to log in without a browser is lgogdownloader's HTML form scraping. It is fragile and breaks when a captcha appears:
  1. `GET auth.gog.com/auth?...&layout=default&brand=gog`. Parse the hidden input `login[_token]` [lgog src/website.cpp:356,388-405].
  2. `POST https://login.gog.com/login_check` with the fields `login[username]`, `login[password]`, `login[login]=` and `login[_token]`. Do not follow redirects [website.cpp:410-438].
  3. If the page HTML contains `class="g-recaptcha form__recaptcha"`, the scraping flow cannot continue. Fall back to the browser [website.cpp:365-374].

### 2FA behaviour (from lgog; a webview handles this for you)
After `login_check`, the redirect Location contains one of two markers [lgog src/website.cpp:445-452]:
- `two_step`: the user gets a 4-character code by email. Send `POST https://login.gog.com/login/two_step` with these fields:
  - `second_step_authentication[token][letter_1..4]`
  - `second_step_authentication[send]=`
  - `second_step_authentication[_token]` (read it from the form)
- `totp`: the user enters a 6-digit authenticator code. Send `POST https://login.gog.com/login/two_factor/totp` with these fields:
  - `two_factor_totp_authentication[token][letter_1..6]`
  - `...[send]`
  - `...[_token]`

Then follow the redirects until one contains `code=` [lgog src/website.cpp:454-600]. In a webview, the login page shows the 2FA step itself, and the final redirect is still `on_login_success?code=...`.

---

## 2. Library

### Owned product IDs
- **`GET https://embed.gog.com/user/data/games`** with `Authorization: Bearer <galaxy token>` returns `{"owned": [<int product ids>...]}`. Sources: [gogdl api.py:65-72], [minigalaxy api.py:182-191]. lgogdownloader uses `https://www.gog.com/user/data/games` [lgog src/website.cpp:849]. The list includes DLC IDs; gogdl uses it to check DLC ownership.
- **Heroic's primary source:** `GET https://galaxy-library.gog.com/users/{user_id}/releases[?page_token=...]` with the Bearer token [heroic backend/storeManagers/gog/library.ts:319-360].
  - Response: `{total_count, next_page_token?, page_token?, limit, items:[{platform_id, external_id, origin, owned, date_created, owned_since, certificate}]}` [heroic common/types/gog.ts:301-318].
  - Follow `next_page_token` until it is absent.
  - Heroic keeps only `platform_id == 'gog'` [library.ts:486-490]. The list also contains linked-store entries.
  - Pass `certificate` to gamesdb as the `X-GOG-Library-Cert` header [library.ts:1349-1354].
- **Legacy paged list** (web account): `GET https://embed.gog.com/account/getFilteredProducts?mediaType=1&page=N` returns `{totalPages, products:[{id,title,url,image,category,...}]}`. Sources: [minigalaxy api.py:90-107], [lgog src/website.cpp:113]. `mediaType=1` means games. The value for movies (probably 2) is **UNCONFIRMED**.

### Metadata endpoints
- **gamesdb** (no auth needed; Heroic still sends Bearer + cert): `GET https://gamesdb.gog.com/platforms/gog/external_releases/{productId}` [heroic library.ts:1349; minigalaxy api.py:375]. It returns an `etag`, and Heroic sends `If-None-Match` [library.ts:1350-1351].
  - Top-level keys [live]: `id, game_id, platform_id, external_id, dlcs_ids, dlcs, parent_id, supported_operating_systems[{slug,name}], available_languages, first_release_date, game{...}, title{'*':...}, sorting_title, type, summary{'*':...}, videos, game_modes, icon, logo`.
  - `game` keys [live]: `title, developers, publishers, genres[{name{'*'}}], themes, screenshots, artworks, summary, visible_in_library, horizontal_artwork, background, vertical_cover, cover, logo, icon, square_icon, releases, slug, ...`.
  - Localised strings use a map keyed by `'*'` and `'en-US'` [heroic common/types/gog.ts:288-292].
- **products API v1**: `GET https://api.gog.com/products/{id}?expand=downloads,expanded_dlcs,description[,screenshots,videos,related_products,changelog]&locale=en-US`. Sources: [gogdl api.py:32-46], [heroic library.ts:1393-1420], [lgog galaxyapi.cpp:356].
  - Batch form: `https://api.gog.com/products?ids=a,b,c&expand=...` [minigalaxy api.py:138-147; lgog galaxyapi.cpp:375]. minigalaxy sends 50 IDs per call. That is its own choice; I did not test a server limit.
  - Fields [live]: `id, title, slug, game_type ('game'|'dlc'|'pack'), content_system_compatibility{windows,osx,linux}, languages, images{background,logo,logo2x,icon,sidebarIcon,...}, dlcs, downloads{installers,patches,language_packs,bonus_content}, expanded_dlcs, description, is_installable, is_secret, in_development`.
  - Offline-installer entries in `downloads.installers[].os` use **`mac`**, not `osx` [live]. `content_system_compatibility` is sometimes wrong [minigalaxy api.py:166-173].
- **products API v2**: `GET https://api.gog.com/v2/games/{id}?locale=en-US` [heroic library.ts:1136-1158]. It is HAL-style: `_links{icon,logo,boxArtImage,backgroundImage,galaxyBackgroundImage,...}` and `_embedded{product, productType, supportedOperatingSystems[{operatingSystem{name},systemRequirements}], ...}` [live]. Heroic uses it for system requirements [library.ts:1165-1200].
- **User**: `GET https://users.gog.com/users/{user_id}` with Bearer returns `username, avatar{...}, ...` [heroic backend/storeManagers/gog/user.ts:79; types gog.ts:152-193]. There is also `https://embed.gog.com/userData.json` [lgog galaxyapi.cpp:603; minigalaxy api.py:303].

### Telling games, DLC, extras and movies apart
- gamesdb `type` is one of `game | dlc | spam | mod`. `game.visible_in_library` also matters. Heroic shows an entry only when `type in ('game','mod') && game.visible_in_library` [heroic library.ts:1074-1082].
- products API `game_type` is one of `game | dlc | pack`.
- Build meta `products[]` lists the base game and its DLC IDs [live].
- Extras (goodies) are `downloads.bonus_content` in the products API. Goodies-only "products" also exist, and minigalaxy blocks them by ID [minigalaxy minigalaxy/constants.py:94-97].
- Movies: `getFilteredProducts` with the movies `mediaType` (**UNCONFIRMED**). They are not in gamesdb as `game`.
- **UNCONFIRMED** (I did not fetch galaxy-library, because it needs auth): the list probably includes DLC IDs as separate entries. Heroic's gamesdb `type` filter in `gogToUnifiedInfo` matches that, so filter the same way.

### Artwork URLs
gamesdb image objects are `{"url_format": "https://images.gog.com/<sha256>{formatter}.{ext}?namespace=gamesdb"}` [live]. **Keep the `?namespace=gamesdb` query.**
- Replace `{formatter}` with `""` (original size) or a known suffix. Replace `{ext}` with `jpg`, `webp` or `png`. All three work [live].
- Suffixes I tested [live]:
  - Return 200: `""`, `_196`, `_glx_vertical_cover`, `_product_tile_256`.
  - Return 400 with JSON: `_2x` and unknown suffixes.
- Heroic's mapping [heroic library.ts:1083-1107]:
  - background = `game.background` (webp)
  - cover (wide) = `game.logo`, falling back to background (jpg)
  - square/vertical = `game.vertical_cover`, falling back to cover (jpg)
  - icon = `game.square_icon || game.icon` (jpg)
  - Heroic uses `''` as the formatter.
- minigalaxy replaces `{formatter}.{ext}` with `.png` [minigalaxy api.py:391].
- Hero image: `game.background` or `game.horizontal_artwork` (for Prison Architect they are the same image) [live].
- Logo: gamesdb `game.logo` holds wide key art, not a transparent logo, at least here [live]. The products API `images.logo` (`..._glx_logo.jpg`) is also key art. A true transparent logo exists in v2 `_links.logo.href` (a png) [live]. **UNCONFIRMED** that it is always transparent.
- products API image URLs are protocol-relative (`//images-N.gog-statics.com/<hash>[_suffix].jpg`), so prefix `https:` [lgog galaxyapi.cpp:418-419]. The same hash accepts the same suffix family on `images.gog-statics.com` (`_196`, `_glx_vertical_cover`, `_product_card_v2_mobile_slider_639` all return 200) [live]. minigalaxy builds thumbnails as `"https:" + image + "_196.jpg"` from `getFilteredProducts.image` [minigalaxy minigalaxy/ui/library_entry.py:610].

---

## 3. Builds

```
GET https://content-system.gog.com/products/{productId}/os/{windows|osx}/builds?generation=2[&password=<pw>][&_version=2]
```
- gogdl's URL is `.../builds?&generation={gen}{password}` (the stray `?&` is harmless). It sends a Bearer token when logged in [gogdl dl/managers/manager.py:39-53].
- The endpoint works **without auth** for public builds [live; gogdl imports.py:51-56 calls it without a token].
- The `generation` defaults to `"2"`; `--force-gen 1|2` exists only for debugging [manager.py:41; args.py:91].
- There is no Linux content system. gogdl sends `linux` to the offline-installer path [manager.py:73-80].

Response [live]:
```json
{ "total_count": 393, "count": 10, "has_private_branches": true,
  "items": [ {
    "build_id": "56279155486691846", "product_id": "1441974651", "os": "windows",
    "branch": null, "version_name": "The_Jailhouse102_11056", "tags": ["..."],
    "public": true, "date_published": "2023-02-24T14:39:31+0000", "generation": 2,
    "link": "https://gog-cdn-fastly.gog.com/content-system/v2/meta/05/9f/059fe48b93b6d1691f158b6ef0404b6e"
  } ] }
```
- Gen1 items add `"legacy_build_id": 65198874` (an int, the v1 "timestamp"). Their `link` is `https://gog-cdn-fastly.gog.com/content-system/v1/manifests/{pid}/{os}/{legacy_build_id}/repository.json` [live]. gogdl v1 reports `legacy_build_id` as the buildId [gogdl dl/managers/v1.py:98].
- **With `_version=2`**, `link` is **replaced** by `urls: [{endpoint_name, url, url_format, parameters:{}, priority, max_fails, supports_generation:[1,2], fallback_only}]` [live; heroic common/types/gog.ts:320-342; heroic library.ts:997-1030].
  - Live values: `fastly` has `priority 10, fallback_only false`; `gcore` has `priority 1, fallback_only true`. Treat fastly as primary.
  - Which way `priority` sorts is **UNCONFIRMED**. lgogdownloader orders by its own user CDN-priority list and uses JSON order as a tiebreak [lgog galaxyapi.cpp:736-806].
- **`generation=2` returns a mix of gen1 and gen2 items.** Old games list gen2 builds first and then their gen1 builds, which have `legacy_build_id` and often an empty `version_name` [live: 1207658924, 1207658691, 1207659026, 1207658930, 1207658753]. `generation=1` returns only gen1 items [live]. So request `generation=2` and dispatch on the chosen item's `generation` [manager.py:122-141].
- Items are ordered newest first [live]. The payload holds only `count` (10) of `total_count` items. **UNCONFIRMED** whether a paging param exists; none of the four clients pages this list.
- `has_private_branches` plus the `password` query param unlock private branches [manager.py:40; heroic library.ts:1001-1004].

### How gogdl picks a build [gogdl dl/managers/manager.py:102-119]
1. Start with `items[0]`.
2. Replace it with the first item where `branch == null` (the default public branch).
3. If `--branch X` was given, replace it with the first item where `branch == X`. Note: with no `--branch`, `self.branch` is `None`, so this step matches `branch == null` again.
4. If `--build <build_id>` was given, replace it with the item that has that `build_id`.
5. Use `generation = target_build["generation"]`. During repair, gogdl uses the stored manifest's `version` instead [manager.py:122-129].

Heroic's update check uses the first `!branch` item's `urls` and an `If-None-Match` etag on the meta URL [heroic library.ts:1015-1065]. gogdl saves the meta response `Etag` as `versionEtag` [gogdl dl/managers/v2.py:279].

---

## 4. Gen 2 (depot) manifests

### Meta ("repository") manifest
- `GET build.link`. The body is **zlib-compressed JSON** with the standard zlib header, decompressed with `zlib.decompress(data, 15)` [gogdl dl/dl_utils.py:22-37; live]. The plain-JSON fallback is kept. lgogdownloader checks for the zlib magic `0x78 0x01/5e/9c/da` [lgog galaxyapi.cpp:147-166].
- URL pattern: `{cdn}/content-system/v2/meta/{h[0:2]}/{h[2:4]}/{h}`. The helper `galaxy_path(h)` inserts the two prefix directories when `h` has no `/` [gogdl dl/dl_utils.py:47-51].
- No auth is needed for meta or depot manifests on the CDN [live].

Fields [live; heroic common/types/gog.ts:467-492; gogdl dl/objects/v2.py:56-68]:
```
version: 2
baseProductId: "1441974651"
buildId: "56279155486691846"
clientId, clientSecret                      # per-game OAuth client (cloud saves)
platform: "windows" | "osx"
installDirectory: "Prison Architect"        # folder name gogdl appends to --path on download (v2.py manager:282-283)
dependencies: ["MSVC2010","MSVC2013",...]   # ids into the dependencies repository (section 6)
scriptInterpreter: true                     # run __redist/ISI/scriptinterpreter.exe post-install (Windows)
tags: [...]
products: [{productId, name, temp_executable, temp_arguments}]   # base game + DLCs
depots: [{productId, languages:[...], manifest:<hash>, size, compressedSize, osBitness?:["64"|"32"], isGogDepot?:true}]
offlineDepot: {productId, languages:["*"], manifest, size, compressedSize}   # contains e.g. project.json
```
- `isGogDepot: true` depots are small depots with the `goggame-{pid}.info` file and the `goggame-{pid}.hashdb` file. Each product (base and every DLC) has its own [live].
- gogdl does not treat `isGogDepot` or `offlineDepot` specially: it ignores `offlineDepot` and treats gog depots as normal depots [gogdl dl/objects/v2.py:83-95].

### Depot selection (languages and DLC) [gogdl dl/objects/v2.py:34-53,83-95]
- Keep a depot when `depot.productId in ownedSelectedDlcIds`, or when `!dlc_only && depot.productId == baseProductId`.
- Then keep it only if some entry in `depot.languages` is `"*"` or equals the target language.
- Language equality [gogdl languages.py:11-20]: the value matches `code` (for example `en-US`), the English `name` (`English`) or a deprecated code (`en`), case-insensitively. So gen1 `"English"` and gen2 `"en-US"` both work.
- The default language is `en-US` [gogdl dl/managers/v2.py:41].
- **osBitness is read but never filtered by gogdl** [gogdl dl/objects/v2.py:38]. lgogdownloader keeps a depot only if `osBitness` contains `"*"` or the target arch, and keeps it when the field is absent [lgog galaxyapi.cpp:640-652]. Filter on 64 in the port, or the install may get both 32- and 64-bit depots where both exist.
- DLC ownership: iterate `meta.products` where `productId != game_id`, and check `does_user_own` against `/user/data/games` [gogdl dl/managers/v2.py:285-306].
- Duplicate paths across depots: lgogdownloader removes a duplicate when the md5 matches. When the md5 differs, the DLC copy wins over the base copy [lgog src/downloader.cpp:4003-4035]. gogdl just appends every item; the last write wins in execution order.

### Depot manifest
- `GET {cdn}/content-system/v2/meta/{galaxy_path(depot.manifest)}`. The body is zlib JSON `{"version":2,"depot":{"items":[...], "smallFilesContainer"?:{...}}}` [gogdl dl/objects/v2.py:128-140; live].
- Item types [gogdl dl/objects/v2.py:10-31,134-140]:
  - `DepotFile`: `{type, path, chunks:[{md5, size, compressedMd5, compressedSize}], md5?, sha256?, flags?:[...], sfcRef?:{offset,size}}`.
    - `md5` (whole file) is present only on some files. When it is absent and there is one chunk, `chunks[0].md5` is the whole-file hash [lgog galaxyapi.cpp:313-318; gogdl task_executor.py:112-113].
    - In live osx manifests, `sha256` is present on every file.
  - `DepotDirectory`: `{type, path}`. Create the directory.
  - `DepotLink`: `{type, path, target}`. Create a symlink on Unix [gogdl dl/workers/task_executor.py:289-296].
  - gogdl treats every other `type` as a directory [gogdl dl/objects/v2.py:139-140].
- `path` uses **backslashes** on both windows and osx builds (for example `PrisonArchitect.app\Contents\Info.plist`) [live]. Normalise with `replace("\\", "/")` and strip the leading separator [gogdl dl/objects/v2.py:13].
- Chunk size seen: 10 MiB uncompressed (`size: 10485760`). In one file the last chunk was larger (17.3 MB), and the largest chunk in that depot was 18,146,426 bytes [live]. This is observed behaviour, not a rule. Do not assume a fixed chunk size; allocate from each chunk's `size`.
- Flags:
  - `executable` → chmod +x after close [gogdl dl/managers/task_executor.py:311-312].
    - osx depots flag every file `executable`, even `.json` and `.jpg` files [live].
  - `support` → the file goes to the support dir at `{support}/{productId}/{path}`, not the game dir [gogdl dl/objects/v2.py:14-15; task_executor.py:26,276].
  - `hidden`: not referenced by gogdl and not seen live. **UNCONFIRMED**.
- Zero-chunk files are created empty [task_executor.py:277-279].

### Small files container (SFC)
- A depot may carry `depot.smallFilesContainer = {chunks:[...]}`. Files packed in it have `sfcRef:{offset,size}`, which points into the concatenated decompressed SFC [lgog galaxyapi.cpp:259-285; live: 235 of 298 osx files].
- **Files with `sfcRef` also have their own `chunks`** [live]. The SFC is therefore only an optimisation to cut request count.
- **gogdl ignores SFC entirely.** It downloads each small file's own chunks [grep: no `sfc` or `smallFiles` anywhere in gogdl].
- lgogdownloader uses the SFC only for a fresh install. If any SFC member file already exists on disk it drops the SFC [lgog src/downloader.cpp:4118-4160]. Otherwise it downloads the SFC once and carves the files out of it at `sfc_offset`/`sfc_size` [downloader.cpp:4285-4341].

### Secure link (chunk base URL)
```
GET https://content-system.gog.com/products/{productId}/secure_link?_version=2&generation=2&path=/
Authorization: Bearer <galaxy token>
```
- Sources: [gogdl dl/dl_utils.py:54-79; lgog galaxyapi.cpp:229-233]. Optional `&root=/patches/store` is used for xdelta patch chunks [gogdl dl/managers/v2.py:173-180].
- gogdl requests **one secure link per product**: the base game and each owned DLC [gogdl dl/managers/v2.py:161-172]. It downloads each chunk with the link of `file.product_id`.
- Without auth the endpoint returns `401 {"error":"access_denied","error_description":"OAuth2 authentication required"}` [live]. Presumably a user who does not own the product is refused too (**UNCONFIRMED** code).
- Response: `{"urls":[{endpoint_name, url, url_format, parameters:{...}, priority, max_fails, supports_generation, fallback_only}]}`. gogdl returns `js['urls']` [dl_utils.py:77-79]. The shape matches the unauthenticated `open_link` response [live].
  - For secure links, `url_format` contains `{...}` placeholders and `parameters` holds their values, including `path`. **UNCONFIRMED**: the exact keys, token/expiry params and URL look.
- **Chunk URL construction** [gogdl dl/workers/task_executor.py:114-126, dl_utils.py:91-96]:
  ```
  e = urls[i]                                  # copy
  e.parameters.path += "/" + galaxy_path(chunk.compressedMd5)   # "/ab/cd/abcd..."
  url = e.url_format with every "{key}" replaced by str(e.parameters[key])
  ```
  lgogdownloader does the same: it appends to the `{path}` param [lgog galaxyapi.cpp:774-786, downloader.cpp:4640-4671].
- Endpoint failover: start at index 0. On each failure move to the next entry; after the last one, go back to 0 and sleep 2 s. Retry 5 times [gogdl dl/workers/task_executor.py:139-187].
- **Expiry:** secure links are time-limited (**UNCONFIRMED** duration). gogdl does not re-fetch on 401/403: it marks the chunk UNAUTHORIZED and resubmits it with the same links [workers/task_executor.py:163-168; managers/task_executor.py:735-739]. lgogdownloader refreshes the OAuth token when it expires and re-fetches the secure link when the product changes [lgog downloader.cpp:4455-4467,4625-4650]. The port should re-fetch the secure link on 401/403.
- Chunk downloads send **no Authorization header and no custom UA**. The worker uses a bare `requests.session()` [gogdl dl/workers/task_executor.py:92].

### Chunk decode and hash checks
- The body of each chunk is a zlib stream with the standard header (`78 9c`) [live]. gogdl decompresses it with `zlib.decompressobj()`, which uses the default wbits (15, header required) [workers/task_executor.py:153-161].
- gogdl verifies during download: `md5(compressed bytes) == chunk.compressedMd5`, otherwise a CHECKSUM failure and a retry [workers/task_executor.py:151,199-201]. **It does not check the uncompressed md5 while downloading.**
- The uncompressed md5 (`chunk.md5`) is checked per chunk only in `repair`/verify [gogdl dl/managers/v2.py:206-214]. Both hashes verified live on a dependency chunk: `md5(body)==compressedMd5` and `md5(inflate(body))==md5` [live].
- Chunks are written in order to the open file. Offsets are implicit: the sum of the previous chunks' `size` values.
- Chunk deduplication: a chunk whose `compressedMd5` appears more than once is written to `.gogdl-download-cache/{md5}` and reused [gogdl dl/managers/task_executor.py:104-128,283-309].
- Resume: after each closed file, gogdl appends a line `"{checksum}:{support|}:{path}"` to `{install}/.gogdl-resume`. On restart, files whose line checksum still matches are skipped [task_executor.py:146-180,757-774].

### Updates (optional)
- Chunk-level diff: reuse old chunks by md5 and `old_offset` [gogdl dl/objects/v2.py:142-161,176-239].
- xdelta3 patches: `GET content-system.gog.com/products/{pid}/patches?_version=4&from_build_id=X&to_build_id=Y` → `{link}` → zlib JSON `{algorithm:"xdelta3", baseProductId, depots:[...]}`. The depot diff manifests are at `{cdn}/content-system/v2/patches/meta/{galaxy_path}` and hold items of `type:"DepotDiff"` with `md5_source, md5_target, path_source, path_target, md5, chunks` [gogdl dl/objects/v2.py:163-175,241-300].

---

## 5. Gen 1 manifests

### Repository
- `GET build.link` = `{cdn}/content-system/v1/manifests/{pid}/{os}/{legacy_build_id}/repository.json`. It is **plain JSON** (not zlib) [live]. gogdl uses `get_zlib_encoded` with its plain fallback [gogdl dl/managers/v1.py:61-71].
- Shape [live; heroic common/types/gog.ts:433-465]:
```
{ "version": 1, "product": {
   "rootGameID": "1441974651", "timestamp": 65198874, "installDirectory": "Prison Architect", "projectName": "...",
   "gameIDs": [{"gameID","name":{"en":...},"dependencies":[],"standalone":true}],
   "depots": [ {"languages":["Neutral"|"English"...],"manifest":"<uuid>.json","gameIDs":["..."],"size":"1259536","systems":["Windows"|"OSX"]},
               {"redist":"<id>","executable","argument","size"} ],
   "support_commands": [{"languages","argument","gameID","systems","executable":"/galaxy_x.exe"}] } }
```
- `size` is a **string**.
- Depot selection: skip `redist` depots. Keep a depot when any of its `gameIDs` is the base game (unless dlc-only) or an owned selected DLC. Language matches `"Neutral"` or the target language (the default is `English`) [gogdl dl/objects/v1.py:9-23,79-92; dl/managers/v1.py:44].
- Redist IDs come from the depots with `redist` [v1.py:63-64]. gogdl resolves them with the **v2** dependencies repository [gogdl dl/managers/dependencies.py:21-22; v1 manager:191-204].

### Depot manifest
- `GET {cdn}/content-system/v1/manifests/{depot.gameIDs[0]}/{platform}/{product.timestamp}/{depot.manifest}`. It is plain JSON [gogdl dl/objects/v1.py:127-134; live].
- Shape: `{"version":1,"depot":{"name":..., "files":[...]}}`. File records:
  - `{path:"/Contents/PkgInfo", offset:<int>, size:<int>, hash:"<md5 of whole file>", url:"1441974651/main.bin", executable?:true, support?:true}`. The leading `/` is stripped [v1.py:36-49].
  - `{directory:true, path}` → a directory [v1.py:131-132].
  - **Symlink records** (osx) [live]: `{path, target:"Versions/Current/SDL2", symlinkType:"file"|"directory"}`, with no size, offset or hash.

### Download
- Secure link: `GET content-system.gog.com/products/{pid}/secure_link?_version=2&type=depot&path=/{platform}/{timestamp}/` with Bearer [gogdl dl/dl_utils.py:58-59; dl/managers/v1.py:181-189].
- URL: take `urls[0]`, set `parameters.path += "/main.bin"`, then fill in `url_format` [gogdl dl/workers/task_executor.py:128-137].
- Fetching `v1/depots/{pid}/main.bin` directly without a signed link returns 403 [live].
- Each file is a **byte range** of `main.bin`: `Range: bytes={offset}-{offset+size-1}` [gogdl dl/dl_utils.py:135-138; workers/task_executor.py:211-218]. gogdl splits large files into ranges of at most `biggest_chunk` bytes. That value is never below 10 MiB, and the last range is smaller [task_executor.py:140-144,204-220].
- The file record's `url` names the blob (`{pid}/main.bin`). gogdl ignores it and always uses `main.bin`. Seen live: one url value per depot.
- Hash checks: during download, gogdl checks only the returned length (`len(buffer) == size`) [workers/task_executor.py:247-249]. The whole-file `md5 == hash` check runs only in repair [gogdl dl/managers/v1.py:230-239].
- A 401 → UNAUTHORIZED [workers/task_executor.py:226-228].

### gogdl gen1 bugs the port should not copy
- `v1.File` appends the flag `"executble"` (typo) [gogdl dl/objects/v1.py:46-47]. The executor checks `'executable'` [task_executor.py:198,222], so gen1 files **never get +x**. This matters for osx.
- `v1.File.__init__` reads `data["size"]` [v1.py:42]. The symlink records in live gen1 osx depots have no `size`, so this raises `KeyError`. Handle `symlinkType`.
- The gen1 osx `.info` file is a **dotfile**: `/Contents/Resources/.goggame-1441974651.info` [live]. gogdl `launch` and `import` look for `goggame-{id}.info` without the dot [gogdl launch.py:302-312; imports.py:98-107].
- `get_secure_link` retries forever by recursion, sleeping 0.2 s, and **drops the `root` argument** on retry [gogdl dl/dl_utils.py:63-75].

---

## 6. Dependencies and redistributables

- `GET https://content-system.gog.com/dependencies/repository?generation=2` → `{"repository_manifest":"https://gog-cdn-fastly.gog.com/content-system/v2/dependencies/meta/e4/be/e4be...","build_id":"59705672826648994","generation":2}` [live; gogdl api.py:55-63]. The v1 URL is `content-system.gog.com/redists/repository` [constants.py:11].
- `repository_manifest` is zlib JSON: `{"depots":[{dependencyId, readableName, executable:{path,arguments}, internal:bool, languages:["*"], manifest, size, compressedSize, signature}]}` [live; heroic common/types/gog.ts:494-507].
  - Examples: `ISI → __redist/ISI/scriptinterpreter.exe`, `MSVC2017 → __redist/MSVC2017/VC_redist.x86.exe "/install /quiet /norestart"`, `DirectX → __redist/DirectX/DXSETUP.exe /silent`, `DOSBox074 → path ""`, `ScummVM → path ""`.
- Depot manifest: `{cdn}/content-system/v2/dependencies/meta/{galaxy_path}` [gogdl dl/managers/dependencies.py:44-48].
- Chunk base: `GET https://content-system.gog.com/open_link?generation=2&_version=2&path=/dependencies/store/` → `{"urls":[{url:"https://gog-cdn-fastly.gog.com/content-system/v2/dependencies/store", ...}]}` [gogdl dl/dl_utils.py:81-88; live].
  - **No auth is needed**, and the URLs are unsigned [live].
  - gogdl builds `url + "/" + galaxy_path(compressedMd5)` using the `url` field, not the template [gogdl dl/workers/task_executor.py:123-125].
  - lgogdownloader instead calls `open_link` with `path=/dependencies/store/{galaxy_path}` for each chunk [lgog galaxyapi.cpp:236-240].
  - Direct fetch verified: `https://gog-cdn-fastly.gog.com/content-system/v2/dependencies/store/2c/5f/2c5f...` → 200, and both hashes match [live].
- Where each dependency goes [gogdl dl/managers/dependencies.py:74-86]:
  - `executable.path` **starts with `__redist`**: a real installer. Heroic downloads these once into a shared redist dir (`gogdl redist --ids ... --path <gogRedistPath>`). It records them in `.gogdl-redist-manifest` [dependencies.py:32,122-126] and runs each installer with its `arguments` under Wine during first-launch setup [heroic backend/storeManagers/gog/setup.ts:331-395]. `PHYSXLEGACY` gets `msiexec /i ... /qb` [setup.ts:374-378].
  - Empty or other `path` (DOSBox*, ScummVM, nGlide, ...): files that the game install needs, **written into the game directory**. The v2 and v1 managers call `DependenciesManager(..., download_game_deps_only=True)` [gogdl dl/managers/v2.py:144-156; v1.py:191-204]. For example, `DOSBOX/DOSBox.exe` goes into the game dir [live].
- Heroic always adds `ISI` to the required list [heroic backend/storeManagers/gog/redist.ts:138,142]. Heroic runs Windows post-install setup only for `platform == windows` [setup.ts:81-87]:
  - `scriptInterpreter: true`: runs `__redist/ISI/scriptinterpreter.exe /VERYSILENT /DIR=<game> /Language=<lang> /LANG=<lang> /ProductId=<pid> /galaxyclient /buildId=<id> /versionName=<v> /lang-code=<en-US> /supportDir=<dir> /nodesktopshorctut /nodesktopshortcut` once for each installed product [setup.ts:227-285].
  - Otherwise: runs `products[].temp_executable` from the support dir [setup.ts:286-327].
  - Gen1: runs `support_commands` [setup.ts:183-225].
  - These steps create registry keys and similar setup for older games.
- Do games work under Wine without the redists? **UNCONFIRMED.** The only evidence is Heroic's own log line: "this shouldn't cause much issues with modern games, but some older titles may need special registry keys" [setup.ts:114-118]. Common practice suggests many games need the MSVC runtimes (Wine ships builtin msvcrt/vcruntime, so often fine) and fewer need DirectX or .NET. Test per game.

---

## 7. Launch

### goggame-{productId}.info
- Delivered by the product's `isGogDepot` depot [live]. Location:
  - windows: `{install}/goggame-{id}.info`
  - osx: `{install}/Contents/Resources/goggame-{id}.info`
  - linux (installer): `{install}/start.sh`
  - Sources: [gogdl launch.py:302-320; heroic library.ts readInfoFile ~1235-1290].
- `goggame-{id}.id` holds `{buildId}` when the info file lacks it [heroic library.ts:1275-1292].
- Shape [heroic common/types/gog.ts:77-114]: `{version, gameId, rootGameId, buildId?, clientId?, standalone, dependencyGameId, language, languages?, name, playTasks:[...], supportTasks?, osBitness?, overlaySupported?}`.
- Tasks:
  - `FileTask{type:"FileTask", path, workingDir?, arguments?, isPrimary?, isHidden?, category?, languages?, osBitness?, compatibilityFlags?}`
  - `URLTask{type:"URLTask", link, name, category}`
  - `category` is one of `game | tool | document | launcher | other`.
  - Example from Heroic's comment: Prison Architect's primary task is `{"category":"launcher","isPrimary":true,"path":"Launcher/dowser.exe"}`, and its hidden `game` task is `Prison Architect64.exe` [heroic common/types.ts:414].
- There is one `.info` file per product installed (base plus each DLC). Heroic lists installed DLC by globbing `goggame-(\d+)\.info` [heroic library.ts:1206-1231]. gogdl import takes `rootGameId` from the first file [gogdl imports.py:117-130].

### How the exe is picked [gogdl launch.py:285-297, 80-108]
- Use the first `playTasks` entry with `isPrimary == true`. `--prefer-task N` picks `playTasks[N]` instead.
- Heroic's fallback is `playTasks[0]`, and it throws on a `URLTask` [heroic library.ts:1296-1322].
- Heroic lists alternative launch options: every `FileTask` that is not `isHidden` and not `category=document` [library.ts:1503-1522].
- `executable = join(install, task.path)`. Working dir = `join(install, task.workingDir or "")`. On non-Windows, `\` becomes `/`, and case-insensitive path resolution follows [launch.py:83-106].
- `arguments` is a string: replace `\` with `/`, then split it shell-style [launch.py:86-90].
- On mac and Linux with a Windows build, wrap the command with `wine` and set `WINEPREFIX` [launch.py:73-78]. Special case: if the exe path contains `scummvm.exe` or `dosbox.exe`, gogdl swaps in a native ScummVM or DOSBox, using flatpak, a mac bundle through `mdfind`, or PATH [launch.py:43-56,110-153].

### macOS builds on disk
- **gen2 osx** (Prison Architect) [live]:
  - The install root contains `Contents\Resources\goggame-*.info` and `.hashdb` from the gog depots, the real bundle `PrisonArchitect.app\Contents\...`, and `Launcher\...`.
  - The root is **not** a proper bundle: it has no root `Contents/Info.plist`.
  - The osx `playTasks.path` content is **UNCONFIRMED**, because reading the `.info` chunk needs auth. It is probably a path to the binary inside the `.app` or to the `.app` itself.
  - gogdl runs `join(install, path)` directly with `Popen` [launch.py:83,278], so a bare `.app` path would fail. Expect a path to a Mach-O inside `*.app/Contents/MacOS/`, or handle an `.app` path with `open -a`/`NSWorkspace`.
- **gen1 osx** [live]: the install root **is** a wrapper bundle: `/Contents/Info.plist`, `/Contents/MacOS/GOGLauncher`, `/Contents/PkgInfo`, `/Contents/Resources/{script.sh, app.icns, .goggame-<id>.info}`. The real game sits at `/Contents/Resources/game/Prison Architect.app/`. Framework symlinks come as symlink records.
- Gen2 osx has no symlink items. Framework `Versions/Current` trees are duplicated as real files [live]. Other games may use `DepotLink`, and gogdl supports it.
- **`.pkg`:** not seen in either content-system generation. Content is always individual files. `.pkg` shows up only in the offline installers (`api.gog.com/products/{id}?expand=downloads` → `installers[os=mac]` → `downlink`) [live: `https://api.gog.com/products/1441974651/downlink/installer/en2installer0`]. gogdl never uses mac offline installers; it uses the content system for osx [gogdl dl/managers/manager.py:73-141].
- **Code signing and quarantine:** not handled by gogdl or Heroic. **UNCONFIRMED** whether downloaded bundles need `xattr -dr com.apple.quarantine` (files written by the app itself are not quarantined unless the app sets it) or an ad-hoc re-sign on Apple Silicon.

---

## 8. Runtime Galaxy services (Galaxy64.dll / comet)

- Heroic runs **comet** (a reimplementation of the Galaxy communication service) during game launch. It spawns `comet --from-heroic --username <username> --quit` before running gogdl `launch` and kills it after the launch [heroic backend/storeManagers/gog/games.ts:730-770]. There is an opt-out: `experimentalFeatures.cometSupport`.
- In the Wine prefix, Heroic copies a **dummy `GalaxyCommunication.exe`** to `C:\ProgramData\GOG.com\Galaxy\redists\GalaxyCommunication.exe`. It registers the file with `sc create GalaxyCommunication binpath=...` and sets `HKLM\SOFTWARE\WOW6432Node\GOG.com\GalaxyClient\paths` `client = C:\Program Files\GOG Galaxy` [heroic backend/launcher.ts:895-940].
- gogdl itself has no runtime component.
- Games that link the Galaxy SDK (`Galaxy.dll`/`Galaxy64.dll`, shipped in the game's own files) try to reach the local service for achievements, overlay, multiplayer and cloud features. **UNCONFIRMED** (general knowledge, not shown in these codebases).
- DRM-free games normally still start without the service. **UNCONFIRMED** from source: nothing in these codebases says so, but it is GOG policy that single-player works offline. Multiplayer or achievements may fail or degrade.
- Achievements and play time use `gameplay.gog.com` [heroic games.ts:148,1388]. Presence uses `presence.gog.com` [heroic presence.ts:55].

---

## 9. Cloud saves (out of scope; endpoints only)

- There is **no `cloudSaves` key in the build repository.** The link is the `clientId`/`clientSecret` pair in the v2 meta.
- Save locations:
  - `GET https://remote-config.gog.com/components/galaxy_client/clients/{clientId}?component_version=2.0.45` → `content.{Windows|MacOS}.cloudStorage.{enabled, locations:[{name, location}]}` [heroic library.ts:243-313; types gog.ts:120-141]. lgogdownloader uses `component_version=2.0.51` [lgog galaxyapi.cpp:224].
  - The location strings contain `<?NAME?>` variables. Heroic finds them with the regex `/<\?(\w+)\?>/g` [heroic backend/save_sync.ts:160]. The variable names are `INSTALL, SAVED_GAMES, APPLICATION_DATA_LOCAL, APPLICATION_DATA_LOCAL_LOW, APPLICATION_DATA_ROAMING, DOCUMENTS, APPLICATION_SUPPORT`, and Heroic's mapping is at [save_sync.ts:136-146; types gog.ts:143-150].
  - When no locations are listed, the default is `%LocalAppData%/GOG.com/Galaxy/Applications/{clientId}/Storage/Shared/Files` on Windows and `$HOME/Library/Application Support/GOG.com/Galaxy/Applications/{clientId}/Storage` on macOS [save_sync.ts:124-134].
- Storage: `https://cloudstorage.gog.com/v1/{user_id}/{clientId}[/{dirname}/{urlencoded path}]`, using the **game** token (section 1):
  - GET list (with `Accept: application/json`), then GET, PUT and DELETE for each file.
  - The UA must be `GOGGalaxyCommunicationService/2.0.13.27 (Windows_32bit) dont_sync_marker/true installation_source/gog`, and the same value goes in `X-Object-Meta-User-Agent` [gogdl saves.py:57-61,210-213,253-330].
  - `X-Object-Meta-LocalLastModified` carries the file mtime [saves.py:316-323].
  - The md5 `aadd86936a80ee8a369579c3926f1b3c` marks a deleted file [saves.py:116,373].

---

## 10. Rate limits, User-Agent and gotchas

- **User-Agent:** nothing shows that a specific UA is required for auth, builds, manifests or chunks.
  - gogdl sends `gogdl/{version} (Heroic Games Launcher)` [gogdl auth.py:25-27; api.py:20-22]. Chunk workers send the default `python-requests` UA [workers/task_executor.py:92].
  - lgogdownloader: `LGOGDownloader/{ver} ({os} {cpu})` [lgog CMakeLists.txt:76]. minigalaxy: `Minigalaxy/{ver} (Linux {arch})` [minigalaxy minigalaxy/minigalaxy.py:113].
  - gogdl import spoofs `GOGGalaxyCommunicationService/2.0.4.164 (Windows_32bit)` on builds [imports.py:51-56]. Use your own honest UA, except for cloudstorage (section 9).
- **Rate limits:** none of the four clients has rate-limit or 429 handling. **UNCONFIRMED** limits.
  - gogdl retries: chunks 5 times with endpoint rotation and a 2 s sleep [workers/task_executor.py:140-187]; meta 5 times with 2 s [dl_utils.py:23-37]; secure link forever at 0.2 s [dl_utils.py:63-75].
  - Default workers = `cpu_count()` [manager.py:26-29].
  - HTTP timeouts: (10 s connect, 30 s read) for general calls and (5, 15) for chunks [gogdl net.py:6; workers/task_executor.py:155].
  - IPv6 note in gogdl: an ISP can hand out IPv6 without routing it, so set timeouts to force the fallback [net.py:1-2].
- **Case-insensitive paths:** manifests can differ in case from files on disk, and between depots.
  - gogdl resolves every path by walking the directories case-insensitively [gogdl dl/dl_utils.py:148-178].
  - gogdl keys diffs, resume and hash maps on `path.lower()` [v2.py:190-202; task_executor.py:106-114,161-172].
  - APFS is case-insensitive by default, but a case-sensitive volume is possible, so keep the lookup.
  - lgogdownloader has an option to lowercase Windows paths [galaxyapi.cpp:288-293].
- **Separators:** gen2 uses `\` even in osx builds; gen1 uses `/` with a leading `/`. Normalise both [v2.py:13,26; v1.py:27,41].
- **Wildcard language:** `"*"` in `depot.languages` means every language [v2.py:47-50]. gen1 uses `"Neutral"` [v1.py:20]. `Language.parse("*")` returns None [languages.py:31-33].
- **Choosing v1 or v2:** always query `builds?generation=2` and branch on the chosen item's `generation`. For a stored install, use the saved manifest's `version` [manager.py:122-141; dl_utils.py:141-146].
  - Moving an install from v1 to v2 compares v1 `hash` with the v2 `md5` or `chunks[0].md5` [v2.py:209-216].
  - Moving from v2 to v1 re-downloads everything [v1.py:160-162].
- **Stored manifest:** gogdl saves the meta to `{config}/heroic_gogdl/manifests/{gameId}` after it adds its own keys `HGLInstallLanguage`, `HGLdlcs` and `HGLPlatform` [v2.py:58-59; v1.py:55-57; v2 manager:270-274]. These keys are **gogdl's additions, not GOG fields**. On macOS the config dir is `~/Library/Application Support/heroic_gogdl` [constants.py:23-26].
- **Auth header scope:** send the Bearer token on content-system, embed, api and gamesdb calls. Do **not** send it on CDN chunk URLs, which are signed. gogdl sends none there.
- **`does_user_own`** fetches `/user/data/games` once and caches it [api.py:65-72].
- **Free-space check:** gogdl sums the uncompressed `size` values minus deletions, plus the chunk-cache temp space, and compares with `shutil.disk_usage` [task_executor.py:73-84,445; dl_utils.py:127-132].
- **Private builds:** a `password` param on builds [manager.py:40]. You may also need it on secure_link (**UNCONFIRMED**).

### Open items from the research (all but 5 answered in "Spike results")
1. The exact `secure_link` `url_format` and `parameters` keys, the token lifetime, and what a non-owner gets.
2. Whether GOG rejects a custom `redirect_uri` at login or at token exchange.
3. The osx `playTasks[].path` form (an `.app` path, or a binary inside it).
4. Live `expires_in` (expected 3600) and whether the refresh token rotates.
5. Whether `builds` has a paging param (only 10 of 393 items are returned). Still open; Playden needs only the first default-branch build.
6. How to read `priority` in `urls[]`.
