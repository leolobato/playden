# Epic Games Store protocol

The wire protocol that `Packages/EpicKit` implements. Requirements are in [PRD 09](prd/09-epic.md).

Research date: 2026-09-29.

## Sources

| Source | Commit | License | How it is used here |
|---|---|---|---|
| legendary (`derrod/legendary`) | `42f6bdeadde3a9526dc8eb713763476999ac217b` (0.21.1 "Lowlife", 2026-09-08) | GPL-3 | Main reference. Playden is GPL-3, so a direct port is allowed. |
| EpicResearch (`MixV2/EpicResearch`) | `f9427462e2159bb0e84ef2aac0b4126bafd5165b` (2023-11-15) | Docs | Grant types, device-code endpoint |
| EpicClients (`Jaren8r/EpicClients`) | `334b41678032ff493d79ee72f6d95372b93b91d7` (2026-09-24) | Docs | Client IDs, allowed grants, permissions |
| DeviceAuthGenerator (`xMistt/DeviceAuthGenerator`) | `8e43868905d52fb18c1ee87bf43813d1c7fac092` (2024-12-13) | Apache-2.0 + Commons Clause | Shows the device-code -> exchange -> other-client flow. Use it as a reference for the flow only. Do not copy its code. |
| `https://api.legendary.gl/v1/version.json` (live) | fetched 2026-09-29 | n/a | legendary's remote config: current EGL version, label, client credentials |

Clone the sources at the commits above to follow the file and line references.

**Live checks on 2026-09-29.** Items marked **[LIVE]** were confirmed against production with curl or Python. No user login was done, so each check used only a client token:
- `client_credentials` works for the Switch client and for the launcher client.
- `deviceAuthorization` works, and so does the "pending" response when polling.
- The catalog bulk-items endpoint works with a launcher client token.
- The manifest API works with a launcher client token for the public EOS Overlay app.
- The CDN manifest download and SHA1 check pass.
- A real chunk downloads **without a CDN token**, and legendary's code parses and verifies it (SHA1 and rolling hash both match).

Items marked **[UNVERIFIED]** are inferred and must be tested with a real account first.

Paths like `egs.py:NN` below mean `legendary/api/egs.py`. `core.py` means `legendary/core.py`, and so on.

---

## 0. Common HTTP setup

- **Hosts** (`egs.py:28-37`, class `EPCAPI`):
  - OAuth / account: `account-public-service-prod03.ol.epicgames.com`. `account-public-service-prod.ol.epicgames.com` also works **[LIVE]**.
  - Launcher (assets, manifests): `launcher-public-service-prod06.ol.epicgames.com`
  - Entitlements: `entitlement-public-service-prod08.ol.epicgames.com`
  - Catalog: `catalog-public-service-prod06.ol.epicgames.com`
  - Ecommerce (ownership token): `ecommerceintegration-public-service-ecomprod02.ol.epicgames.com`
  - Library: `library-service.live.use1a.on.epicgames.com`
  - Cloud saves: `datastorage-public-service-liveegs.live.use1a.on.epicgames.com`
  - Store GraphQL (achievements, Uplay): `launcher.store.epicgames.com/graphql`
- **User-Agent** (`egs.py:21,67-73`): `UELauncher/{egl_version} Windows/10.0.19041.1.256.64bit`.
  - legendary hardcodes `11.0.1-14907503+++Portal+Release-Live` and overrides it at runtime from `api.legendary.gl/v1/version.json` → `egl_config.version` (`core.py:apply_lgd_config`, line 307).
  - The current value is `15.18.2-29993784+++Portal+Release-Live`. So today's UA is `UELauncher/15.18.2-29993784+++Portal+Release-Live Windows/10.0.19041.1.256.64bit`.
  - Store GraphQL calls use `EpicGamesLauncher/{egl_version}` instead (`egs.py:22`).
  - Recommendation: ship a default UA and allow a remote or config override. The same applies to client ID/secret (see 1a).
- **Auth header:** `Authorization: bearer <access_token>`. legendary uses lowercase `bearer` for API calls and HTTP Basic for the token endpoint.
- **CDN downloads** (manifests and chunks) use a session **without** the Authorization header (`egs.py:48`, `unauth_session`), with the same UA.
- **Timeouts:** 10 s per request by default (`egs.py:39`).
- **Errors:** Epic returns JSON like `{errorCode, errorMessage, messageVars, numericErrorCode, originatingService, intent}`. legendary raises only on status ≥500 and checks `errorCode` for everything else (`egs.py:start_session`, `resume_session`).

---

## 1. Auth

### 1a. legendary's launcher client

- **Client:** `launcherAppClient2`. ID `34a02cf8f4414e29b15921876da36f9a`, secret `daafbccc737745039dffe53d94fc76cf` (`egs.py:24-25`). The live `egl_config` returns the same pair.
  - Allowed grants (EpicClients `clients/34a02cf8….md`): `authorization_code`, `client_credentials`, `exchange_code`, `refresh_token`.
  - It does **not** allow `device_code`. It has permission `account:oauth:exchangeTokenCode ALL`, so it can create exchange codes for launching games.
  - legendary lets `version.json` override the pair (`egs.py:update_egs_params`, lines 78-81). Do the same, so Playden can pick up a rotation without shipping a new build.
- **Token endpoint** (`egs.py:start_session`, lines 100-144): `POST https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/token`
  - Headers: `Authorization: Basic base64(clientId:secret)`, `Content-Type: application/x-www-form-urlencoded`, UA.
  - Body (form), one of:
    - `grant_type=authorization_code&code=<code>&token_type=eg1`
    - `grant_type=exchange_code&exchange_code=<code>&token_type=eg1`
    - `grant_type=refresh_token&refresh_token=<rt>&token_type=eg1`
    - `grant_type=client_credentials&token_type=eg1` (anonymous; legendary does not set `user` in this case)
  - `token_type=eg1` returns JWT access tokens prefixed `eg1~` **[LIVE]**.
  - Response fields used: `access_token`, `expires_in`, `expires_at` (ISO8601 with `Z`), `refresh_token`, `refresh_expires`, `refresh_expires_at`, `account_id`, `displayName`, `client_id`, `token_type`.
  - legendary stores the whole JSON as `user.json` (see `core.py:auth_code` and `auth_ex_token`).
  - **Lifetimes:** do not hardcode them. Read `expires_in`/`expires_at` and `refresh_expires(_at)` from each response. A `client_credentials` token is `expires_in: 14400` (4 h) for both launcher and Switch clients **[LIVE]**. User-token lifetimes were not observed in this research.
  - **Error handling:** if `errorCode == errors.com.epicgames.oauth.corrective_action_required`, the response includes `correctiveAction` and `continuationUrl`. Show the user the URL, because they must accept EULA or privacy terms on the web (`egs.py:129-131`). Any other `errorCode` means invalid credentials.
- **Initial login in legendary** (`cli.py:auth`, lines 93-208; `utils/webview_login.py`):
  1. WebView login at `https://www.epicgames.com/id/login` with JS injected into `window.ue.signinprompt`. It receives an exchange code, then uses the `exchange_code` grant.
  2. Or manual: the user opens `https://legendary.gl/epiclogin`, which redirects to `https://www.epicgames.com/id/login?redirectUrl=https://www.epicgames.com/id/api/redirect?clientId=34a02cf8…&responseType=code` (`egs.py:get_auth_url`). They copy `authorizationCode` from the JSON, and legendary uses the `authorization_code` grant.
  3. Or from an SID: `core.py:auth_sid` (lines 123-155) calls `GET /id/api/set-sid?sid=`, then `GET /id/api/csrf`, then `POST /id/api/exchange/generate` with `X-XSRF-TOKEN`. This returns an exchange code.
  4. Or import the refresh token from EGL's `RememberMe` config (`core.py:auth_import`). This does not apply to Playden.
- **Resume, refresh and verify** (`core.py:_login`, lines 211-278):
  - If a stored session has more than 600 s left, verify it with `GET https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/verify` and a bearer token (`egs.py:resume_session`). A response containing `errorMessage` or `errorCode` means the token is invalid. Otherwise, merge the response into the session.
  - If verify fails or less than 10 minutes remain, use the `refresh_token` grant.
  - If refresh returns an `errorCode` (`InvalidCredentialsError`), clear the stored credentials and ask the user to log in again. On a network error, keep the credentials.
- **Logout / kill session:** `DELETE https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/sessions/kill/{access_token}` with bearer (`egs.py:invalidate_session`; legendary never calls it). legendary's `auth --delete` only deletes local `user.json`. Playden should call kill on logout, then delete the Keychain item.
- **Exchange code (used for launch and for 1b):** `GET https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/exchange` with bearer (`egs.py:get_game_token`).
  - Response: `{expiresInSeconds: 300, code: "<32 hex>", creatingClientId: "<client>"}`.
  - The code is single use and valid for 300 s (EpicResearch `exchange_code.md`).
  - Only `code` is read (`core.py:get_launch_parameters`).
- **Is a client_credentials token needed first?** Not for the launcher client. legendary never uses one for user flows. It is needed for device-code sign-in (1b), and only on the Switch client.

### 1b. Device-code sign-in for a TV (code or QR on screen, sign in on a phone)

**Summary:** Epic's account service supports the OAuth device flow only for console-type clients. Use a Switch Fortnite client to get a user token, create an exchange code with it, then redeem that code with `launcherAppClient2`. The result is a normal launcher session, the same kind legendary has.

**Clients that allow `device_code`** (EpicClients `README.md`, per-client pages):

| Client | ID | Secret | Grants | Exchange-code permission |
|---|---|---|---|---|
| fortniteSwitchGameClient ("New Switch", `prod-fn`) | `98f7e42c2e3a4f86a74eb43fbb41ed39` | `0a2449a2-001a-451e-afec-3e812901c4d7` | client_credentials, device_code, external_auth, refresh_token | `account:oauth:exchangeTokenCode ALL` (line 56) |
| fortniteSwitchGameClient (old) | `5229dcd3ac3845208b496649092f251b` | `e3bd2d3e-bf8c-4857-9e7d-f3d947d220c7` | client_credentials, device_auth, device_code, external_auth, refresh_token | `account:oauth:exchangeTokenCode ALL` (line 54) |
| also: fortnitePS4US/EU, XboxGameClient, XSXGameClient, XboxAllyGameClient | see EpicClients README | | include device_code | |

**Recommendation:** use `98f7e42c…` (**[LIVE]**, working today). It is the client used by DeviceAuthGenerator and by the Fortnite bot community. Keep `5229dcd3…` as a configurable fallback.

**Which endpoint:**
- Use the **account-public-service** endpoint, not `api.epicgames.dev`.
- The EOS endpoints (`api.epicgames.dev/epic/oauth/v2/token`, `.../deviceAuthorization`) belong to EOS applications. EOS tokens are EOS/Epic Account Services tokens with a different permission model, and legendary's launcher, library and manifest calls do not accept them.
- No public source uses EOS device-code tokens for launcher APIs.

**Flow (steps 1-3 [LIVE]; steps 4-5 [UNVERIFIED], see the reliability notes):**

1. **Client token (Switch client).**
   `POST https://account-public-service-prod.ol.epicgames.com/account/api/oauth/token`
   `Authorization: Basic base64("98f7e42c2e3a4f86a74eb43fbb41ed39:0a2449a2-001a-451e-afec-3e812901c4d7")`
   Body: `grant_type=client_credentials`
   Response [LIVE]: `{access_token, expires_in:14400, expires_at, token_type:"bearer", client_id, internal_client:true, client_service:"prod-fn", product_id, application_id}`.

2. **Start the device authorization.**
   `POST https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/deviceAuthorization`
   `Authorization: bearer <client token>`, `Content-Type: application/x-www-form-urlencoded`
   Body: `prompt=login` (optional; EpicResearch `get_device_authorization.md` lists `login` or `register`)
   Response [LIVE]:
   ```json
   {"user_code":"BWBPPHXT","device_code":"<opaque>","verification_uri":"https://www.epicgames.com/activate",
    "verification_uri_complete":"https://www.epicgames.com/activate?userCode=BWBPPHXT",
    "prompt":"login","expires_in":600,"interval":10,"client_id":"98f7e42c2e3a4f86a74eb43fbb41ed39"}
   ```
   TV UI: show `user_code` in large text and `verification_uri` as text. Render a QR code for `verification_uri_complete`. Start a 600 s countdown.

3. **Poll** every `interval` seconds (10):
   `POST https://account-public-service-prod.ol.epicgames.com/account/api/oauth/token`
   Switch Basic auth. Body: `grant_type=device_code&device_code=<device_code>`
   - While waiting [LIVE]: HTTP 400 `{"errorCode":"errors.com.epicgames.account.oauth.authorization_pending","numericErrorCode":18115,…}`. Keep polling.
   - DeviceAuthGenerator also treats `errors.com.epicgames.not_found` as "keep polling" (`generator.py:wait_for_device_code_completion`).
   - Any other `errorCode`, or passing `expires_in`, means stop and offer a new code.
   - On HTTP 200 you get a Switch-client user token (`access_token`, `account_id`, `displayName`, …).

4. **Create an exchange code with the Switch user token.**
   `GET https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/exchange`
   `Authorization: bearer <switch user token>`. Response: `{code, expiresInSeconds:300, creatingClientId}`.

5. **Redeem with the launcher client.**
   `POST https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/token`
   `Authorization: Basic base64("34a02cf8f4414e29b15921876da36f9a:daafbccc737745039dffe53d94fc76cf")`
   Body: `grant_type=exchange_code&exchange_code=<code>&token_type=eg1`
   The result is a normal launcher session, the same as legendary's `auth_ex_token`. Store `refresh_token` and use 1a from here on.

6. **Clean up:** `DELETE /account/api/oauth/sessions/kill/{switch user access_token}`. Throw away the Switch refresh token.

**Reliability and evidence:**
- Steps 1-3 were run against production today [LIVE].
- Steps 4-5 (Switch-created exchange code redeemed by `launcherAppClient2`) were **not** run end to end, because that needs a real account. Confidence is high:
  - DeviceAuthGenerator (`generator.py:95-150`) runs this same flow (Switch `client_credentials` → `deviceAuthorization` → `device_code` poll → `GET /oauth/exchange` → `exchange_code` grant) and redeems with a **different** client (fortniteAndroidGameClient `3f69e56c…`). So Epic accepts cross-client redemption of exchange codes.
  - legendary itself redeems exchange codes created by the web client (`auth_sid`, webview) with the launcher client.
  - Every EGL game launch redeems a launcher-created exchange code with the game's own client.
  - Both Switch clients have `account:oauth:exchangeTokenCode ALL`, and the launcher client allows `exchange_code`.
- **First task in implementation: test this with a real account.** Then confirm that `library/api/public/items` and the assets/manifest endpoints accept the resulting token.
- **Risks:**
  - The user sees a "Fortnite"-branded consent page. `prompt=login` makes Epic ask for a fresh login.
  - Epic can disable or rotate console client secrets at any time. The EpicClients table lists some old IDs as disabled.
  - The flow is unofficial. Make client IDs remotely configurable, as legendary does, and keep the WebView/authorization-code login (1a) as a fallback.
  - Accounts with 2FA complete 2FA on the phone, so the TV needs no change.
- **Alternative with the same UX but more work:** show a QR code for `https://legendary.gl/epiclogin`-style authorization URLs (1a option 2). This does not work well, because the user must copy the JSON code back by hand. The device flow is the only real phone-completes-the-login option.

---

## 2. Library

legendary builds its library from **assets** (anything installable), with **catalog** metadata added. It uses **library-service** only for items that have no asset (EA/Ubisoft, and similar).

### 2a. Assets (installable apps, per platform)
`GET https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/public/assets/{platform}?label=Live`. The bearer must be a user token (`egs.py:get_game_assets`).
- `platform`: `Windows`, `Mac`, or `Win32`. legendary always fetches `Windows`, plus the requested platform and any installed platforms (`core.py:get_game_and_dlc_list`, lines 530-537).
- Response: a JSON array. Each element has `appName`, `labelName`, `buildVersion`, `catalogItemId`, `namespace`, `assetId`, `metadata` (dict), `sidecarRvn` (int) (`models/game.py:GameAsset.from_egs_json`, lines 22-33).
  - Compare `buildVersion` with the installed version to detect updates (`core.py:is_latest`; `cli.py:launch_game` refuses to launch outdated games unless `--skip-version-check` is set).
- legendary fetches entitlements when assets change: `GET https://entitlement-public-service-prod08.ol.epicgames.com/entitlement/api/account/{account_id}/entitlements?start=N&count=1000`, paged until a page has fewer than 1000 items (`egs.py:get_user_entitlements_full`). legendary does not use them for filtering, so Playden can skip this call.

### 2b. Library items (ownership incl. non-installable)
`GET https://library-service.live.use1a.on.epicgames.com/library/api/public/items?includeMetadata=true[&cursor=<c>]` with bearer (`egs.py:get_library_items`, lines 239-257).
- Response: `{records:[…], responseMetadata:{nextCursor?, stateToken?}}`. Loop while `responseMetadata.nextCursor` is present.
- Record fields used: `namespace`, `catalogItemId`, `appName` (can be missing), `sandboxType`. Also present (not used by legendary): `productId`, `sandboxName`, `recordType`, `acquisitionDate`.
- Filters (`core.py:get_non_asset_library_items`, lines 652-692):
  - skip `namespace == "ue"` (Unreal Marketplace)
  - skip records with no `appName`
  - skip app names that already have an asset
  - skip `appName == "1"`
  - skip `sandboxType == "PRIVATE"`

### 2c. Catalog metadata
`GET https://catalog-public-service-prod06.ol.epicgames.com/catalog/api/shared/namespace/{namespace}/bulk/items?id={catalogItemId}&includeDLCDetails=true&includeMainGameDetails=true&country={CC}&locale={lc}` (`egs.py:get_game_info`).
- A client_credentials launcher token works here [LIVE], so metadata can be fetched without a user token.
- Response: `{ "<catalogItemId>": item }`.
- Item fields [LIVE, from the EOS Overlay and audience items]:
  - `id`, `title`, `description`, `keyImages[]`, `categories[{path}]`, `namespace`, `status`
  - `creationDate`, `lastModifiedDate`
  - `customAttributes{Key:{type:"STRING",value:"…"}}`
  - `entitlementName`, `entitlementType` (`EXECUTABLE` for games; `AUDIENCE` for store audience items)
  - `itemType`
  - `releaseInfo[{id, appId, compatibleApps[], platform[], dateAdded, releaseNote, versionTitle}]`
  - `developer`, `developerId`, `eulaIds`, `endOfSupport`, `mainGameItemList`, `ageGatings`, `applicationId`, `requiresSecureAccount`, `unsearchable`
  - DLC items also have `mainGameItem` (a full item with `releaseInfo[0].appId` = base game app name). Base games list `dlcItemList[]` when `includeDLCDetails=true`. These last two are recalled, and legendary reads them.
- **keyImages** entries: `{type, url, md5, width, height, size, uploadedDate}`. The shape is recalled; the sample items had empty arrays.
  - Common `type` values: `DieselGameBoxTall` (portrait cover, ~1200×1600), `DieselGameBox` (landscape hero, ~2560×1440), `Thumbnail`, `DieselGameBoxLogo` (transparent logo), `DieselStoreFrontWide`, `DieselStoreFrontTall`, `OfferImageWide`, `OfferImageTall`, `CodeRedemption_340x440`, `Screenshot`.
  - Suggested fallback order: portrait `DieselGameBoxTall` → `OfferImageTall` → `Thumbnail`; landscape `DieselGameBox` → `OfferImageWide` → `DieselStoreFrontWide`.
  - Images take resize params such as `?h=480&resize=1&w=360`. **[UNVERIFIED]**
- **customAttributes** that matter (legendary accessor → file):
  - `CanRunOffline` → offline launch allowed. Treat as `true` if absent (`core.py:prepare_download`, line 1677).
  - `OwnershipToken` = `"true"` → needs a `.ovt` file at launch (same place). legendary warns that this "likely uses Denuvo" (`core.py:check_installation_conditions`).
  - `RequiresOwnership`: exists in metadata, but legendary does not read it.
  - `FolderName` → default install folder name. Falls back to `app_name`; DLC uses the base game's value (`core.py:prepare_download`).
  - `ThirdPartyManagedApp` or `ThirdPartyManagedProvider` → third-party store, e.g. `Origin`, `The EA App`, `UbisoftConnect` (`models/game.py:third_party_store`, `is_origin_game`, `is_ubisoft_game`).
  - `partnerLinkType` (e.g. `ubisoft`) and `partnerLinkId` → one-time account link to activate the title (`models/game.py`).
  - `AdditionalCommandLine` → extra game args (`models/game.py:additional_command_line`). Note the spelling: `get_origin_uri`/`get_ubisoft_uri` read `AdditionalCommandline` with a lowercase "l", a probable legendary inconsistency. Read both.
  - `CloudSaveFolder` and `CloudSaveFolder_MAC` → cloud save support.
  - `GameID` → Ubisoft game id for the `uplay://` URI.
  - `SupportedPlatforms` → a string such as `"Windows"` [LIVE].
- **categories:** `path == "mods"` is excluded from the game list. `addons/launchable` is a launchable add-on: launch the base game with this app name as `-epicapp` (`models/game.py:is_launchable_addon`; `cli.py:launch_game`, lines 605-611). Also seen: `games`, `applications`, `addons`, `digitalextras`, `audience`, `public`.
- **Sidecar** (for `-epicdeploymentid`): fetched only when asset `sidecarRvn > 0`. It comes from the manifest API response `elements[0].sidecar = {config: "<JSON string>", rvn}`. Parse `config` with JSON and read `deploymentId` (`core.py:get_game_and_dlc_list/fetch_game_meta`, lines 572-601).

### 2d. How legendary builds the list (`core.py:get_game_and_dlc_list`, lines 523-631)
1. Group assets by `appName`, across all fetched platforms.
2. Skip any app whose asset has `namespace == "ue"` (`skip_ue`).
3. Fetch metadata again when there is no cache, when `buildVersion` changed, when the sidecar rvn changed, or on force refresh. legendary uses a 16-thread pool with a 60 s map timeout, and retries serially on failure.
4. DLC (`'mainGameItem' in metadata`) is grouped under `metadata.mainGameItem.id` (the base game's catalogItemId). A base game's DLCs are `dlcs[game.catalog_item_id]` (`get_dlc_for_game`).
5. Games in the `mods` category are excluded. Only apps with an asset for the requested platform are returned.
6. **Third-party titles:** games with `third_party_store` set cannot be installed (`cli.py:install_game`, lines 891-896).
   - EA/Origin: launch via `link2ea://launchgame/{app_name}?AUTH_PASSWORD=<exchange>&AUTH_TYPE=exchangecode&epicusername=…&epicuserid=…&epiclocale=…` (`core.py:get_origin_uri`).
   - Ubisoft: `uplay://launch/{GameID}?…` (`core.py:get_ubisoft_uri`).
   - Both need the vendor's launcher. Out of scope for Playden: show them as "Requires EA app / Ubisoft Connect" and hide install.
7. Also in `check_installation_conditions`: if every `.exe` in the manifest has "uplay" in its name, legendary fails with "requires installation via Uplay". It also flags a Uplay/Ubisoft prereq path.

---

## 3. Manifests and download

### 3a. Manifest API
`GET https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/public/assets/v2/platform/{platform}/namespace/{namespace}/catalogItem/{catalogItemId}/app/{appName}/label/Live` with bearer (`egs.py:get_game_manifest`).
- Response [LIVE, EOS Overlay, launcher client_credentials token]:
  ```json
  {"elements":[{"appName":"98bc04bc…","labelName":"Live-Windows","buildVersion":"1.3.7++EOSSDK+…",
    "hash":"1af9fd47…(sha1 of manifest file)","useSignedUrl":false,
    "manifests":[
      {"uri":"https://egs-cloudfront-chunks.epicgamescdn.com/Builds/EOS/OverlayCloudDir/<id>.manifest","queryParams":[{"name":"cf_token","value":"…"}]},
      {"uri":"https://epicgames-download1.akamaized.net/Builds/…/<id>.manifest","queryParams":[{"name":"ak_token","value":"…"}]},
      {"uri":"https://egdownload.fastly-edge.com/Builds/…/<id>.manifest","queryParams":[{"name":"f_token","value":"…"}]}],
    "isPreloaded":false}]}
  ```
  Optional fields: `secrets` (dict for encrypted v22+ manifests) and `sidecar` (`core.py:get_cdn_urls`, lines 1398-1422).
- legendary raises an error if `elements` has more than one entry.
- Manifest URLs: `uri + "?" + "&".join(name=value)` (the values are CDN tokens). Try the URLs in order and use the first HTTP 200 (`core.py:get_cdn_manifest`, lines 1424-1453).
- **Base URLs for chunks:** `uri.rpartition('/')[0]`, de-duplicated, **with no query params**. Chunk GETs work without a token [LIVE]. legendary uses `base_urls[0]` unless the user sets `preferred_cdn` (`core.py:prepare_download`, ~lines 1615-1640).
- Verify `sha1(manifest_bytes).hexdigest() == elements[0].hash` [LIVE: matched].
- EGL uses plain HTTP by default so that LAN caches can intercept it. legendary offers `disable_https` as an option. Use HTTPS.
- The CDN hosts seen today are `egs-cloudfront-chunks.epicgamescdn.com`, `epicgames-download1.akamaized.net` and `egdownload.fastly-edge.com`. Do not hardcode them; always use what the API returns.
- Keep `base_urls` with the install, as legendary does in `InstalledGame.base_urls`. Refresh them on every update, because old CDNs die.
- A manifest that starts with `{` is JSON. Anything else is binary (`core.py:load_manifest`, line 1387).

### 3b. Binary manifest format (`models/manifest.py`)
All integers are little-endian.

**FString** (`read_fstring`, lines 18-34): `int32 len`.
- `len > 0`: ASCII, `len` bytes including a NUL.
- `len < 0`: UTF-16LE, `-len` code units including a 2-byte NUL.
- `len == 0`: empty string, no bytes.

**Header** (`Manifest.read`, lines 155-186):

| off | type | field |
|---|---|---|
| 0 | u32 | magic `0x44BEC00C` |
| 4 | u32 | header_size (41, or 73 if version ≥ 22) |
| 8 | u32 | size_uncompressed |
| 12 | u32 | size_compressed |
| 16 | 20 B | sha1 of the **decompressed** body |
| 36 | u8 | stored_as: `0x1` zlib-compressed, `0x2` encrypted |
| 37 | u32 | version |
| 41 | 16 B | (v ≥ 22) secret_guid as 4×u32 |
| 57 | 16 B | (v ≥ 22) encryption_tag (AES-GCM tag) |

- Seek to `header_size`.
- If compressed, the rest is zlib: decompress it and check SHA1 against the header.
- The sample overlay manifest had version 16, header 41 and `stored_as` 0 (not compressed) [LIVE], so both cases must be handled.

**Body = Meta, then CDL, then FML, then CustomFields, then (encrypted only) EncryptedData.** Each section begins with `u32 size`, `u8 version`, and usually `u32 count`. Always seek to `section_start + size` at the end, so newer fields are skipped safely (legendary does this).

**ManifestMeta** (`ManifestMeta.read`, lines 315-356), in order:
- `u32 meta_size`, `u8 data_version`, `u32 feature_level`, `u8 is_file_data`, `u32 app_id`
- FStrings `app_name`, `build_version`, `launch_exe`, `launch_command`
- `u32 n` + n × FString `prereq_ids`
- FStrings `prereq_name`, `prereq_path`, `prereq_args`
- if `data_version ≥ 1`: FString `build_id`
- if `data_version ≥ 2`: FStrings `uninstall_action_path`, `uninstall_action_args`

If `build_id` is absent, compute it (`ManifestMeta.build_id`, lines 300-312): `sha1(u32le(app_id) + app_name + build_version + launch_exe + launch_command)`, then base64url without padding (`+`→`-`, `/`→`_`, strip `=`).

**CDL / chunk data list** (`CDL.read`, lines 449-505).

Header: `u32 size`, `u8 version`, `u32 count`. The fields that follow are **stored as arrays, one field at a time** (all GUIDs, then all hashes, and so on):
- count × GUID (4×u32 LE)
- count × u64 rolling hash
- count × 20 B sha1 (of uncompressed chunk data)
- count × u8 group_num
- count × u32 window_size (uncompressed size; 1048573 in the sample, so do not assume exactly 1 MiB)
- count × i64 file_size (compressed download size)
- if manifest version ≥ 22: count × 16 B secret_guid, count × u32 window_size_compressed, count × 16 B encryption_tag

**Chunk path** (`ChunkInfo.path`, lines 592-603; `get_chunk_dir`, lines 54-65):
- dir by manifest version (use feature_level/version): ≥22 `ChunksV5`, ≥15 `ChunksV4`, ≥6 `ChunksV3`, ≥3 `ChunksV2`, otherwise `Chunks`.
- v < 22: `{dir}/{group_num:02d}/{hash:016X}_{guid[0]:08X}{guid[1]:08X}{guid[2]:08X}{guid[3]:08X}.chunk`
  [LIVE] example: `ChunksV4/82/B347FC52BDC6D23F_1C45C7A14957596554012FBF7CF64B16.chunk`
- v ≥ 22: `{dir}/{secret|"plain"}/{group:02d}/{b64url(u64le hash)}_{b64url(4×u32le guid)}.chunk`, with the base64 padding stripped. `secret` is the base64url of the secret_guid, or `plain` if it is all zero.
- JSON manifests compute group_num as `crc32(4×u32le guid) % 100` (`ChunkInfo.group_num`). Binary manifests store it.
- **Chunk URL:** `base_url + "/" + path` (`downloader/mp/manager.py`, line 465).

**FML / file manifest list** (`FML.read`, lines 626-702). Also stored as arrays, one field at a time.

Header: `u32 size`, `u8 version`, `u32 count`, then:
- count × FString filename (path uses `/`, relative to the install dir)
- count × FString symlink_target
- count × 20 B sha1 (whole-file SHA1; used for verify)
- count × u8 flags: `0x1` read-only, `0x2` compressed, `0x4` executable (chmod +x on unix)
- per file: `u32 n` + n × FString install_tags
- per file: `u32 n` chunk parts. Each part is `u32 part_size (28)`, GUID (16), `u32 offset` (into the chunk's uncompressed data), `u32 size`. Skip `part_size - 24` extra bytes if present. file_offset is the running sum of the sizes.
- if FML version ≥ 1: per file `u32 has_md5` (+16 B md5 if non-zero), then per file FString mime_type
- if FML version ≥ 2: per file 32 B sha256

`file_size = Σ part.size`.

**CustomFields** (`CustomFields.read`, lines 851-871): `u32 size`, `u8 version`, `u32 count`, count × key FString, then count × value FString.

**EncryptedData** (feature_level ≥ 24; `EncryptedData.read` and `EncryptedDataHeader.read`, lines 906-979; `Manifest.decrypt`, lines 98-129):
- `u32 size`, `u8 version`, `u32 cipher_size`, then:
  - header: `u32 size`, `u32 version`, `u8 stored_as`, `u32 uncompressed`, `u32 compressed`, `u32 iv_len`, iv
  - `u32 ciphertext_size`, ciphertext
- Key: `secrets[secret_guid as "%08X%08X%08X%08X"]`, hex → bytes. The secrets come from the manifest API `secrets`.
- AES-GCM with nonce = iv and tag = header `encryption_tag`. zlib-decompress if `header.stored_as & 1`.
- The plaintext holds FStrings: `launch_exe`, `launch_command`, `u32 n` prereq_ids, `prereq_name`, `prereq_path`, `prereq_args`, `uninstall_action_path`, `uninstall_action_args`. Then, for each FML file in order, `filename` and `symlink_target`. In encrypted manifests these fields are blank in plaintext.
- If decryption fails, abort. legendary says "preloading isn't implemented yet" (`core.py:prepare_download`, lines 1528-1530). Preloaded (not yet released) builds come without keys.
- Use CryptoKit `AES.GCM` for this.

### 3c. JSON manifest variant (`models/json_manifest.py`)
Old titles only. Numbers are "blobs": each byte is written as 3 decimal digits, little-endian (`blob_to_num`: `num += int(s[i:i+3]) << (8*(i/3))`). GUIDs are 32 hex chars read as big-endian 4×u32 (`guid_from_json`).

Keys:
- `ManifestFileVersion`, `bIsFileData`, `AppID`, `AppNameString`, `BuildVersionString`, `LaunchExeString`, `LaunchCommand`, `PrereqIds`, `PrereqName`, `PrereqPath`, `PrereqArgs`
- `ChunkFilesizeList{guid:blob}`, `ChunkHashList{guid:blob}`, `ChunkShaList{guid:hex}`, `DataGroupList{guid:blob}`
- `FileManifestList[{Filename, FileHash(blob→20 B LE), bIsReadOnly, bIsCompressed, bIsUnixExecutable, InstallTags, FileChunkParts[{Guid, Offset, Size}]}]`
- `CustomFields`

window_size is taken to be 1 MiB. The default version is 13 → `ChunksV3`.

### 3d. Chunk file format (`models/chunk.py:Chunk.read`, lines 98-131)

| field | type | from header version |
|---|---|---|
| magic `0xB1FE3AA2` | u32 | 1 |
| header_version | u32 | 1 |
| header_size | u32 | 1 |
| compressed_size | u32 | 1 |
| guid | 4×u32 | 1 |
| rolling hash | u64 | 1 |
| stored_as (`0x1` zlib, `0x2` AES-GCM) | u8 | 1 (header = 41 B) |
| sha1 | 20 B | 2 |
| hash_type (`0x1` rolling, `0x2` sha1, `0x3` both) | u8 | 2 (header = 62 B) |
| uncompressed_size | u32 | 3 (header = 66 B) |
| secret_guid | 4×u32 | 4 |
| encryption_tag | 16 B | 4 (header = 98 B) |

- The data after the header is decoded in this order (`Chunk.data`):
  1. If encrypted, AES-GCM with key `secrets[secret_guid hex upper]`, nonce = `sha1[:12]` and tag = encryption_tag.
  2. If compressed, `zlib.decompress`.
- [LIVE] The sample chunk had header v3 (66 B), stored_as 1 and hash_type 3. It was 86187 B compressed and 1048573 B uncompressed.
- **Verify every chunk.** legendary's `DLWorker.run` does **not** re-hash downloaded chunks; it trusts zlib. Playden should check `SHA1(uncompressed) == CDL sha1` [LIVE: matches]. The rolling hash also matches the CDL `hash` [LIVE], but SHA1 is enough.
- **Rolling hash** (`utils/rolling_hash.py`): a CRC-64 table with poly `0xC96C5795D7870F42` (reflected), then `h = rotl64(h,1) ^ table[byte]` for each byte. It is only needed to create chunks, not to download them.

### 3e. Assembling files (`downloader/mp/manager.py:run_analysis`, lines 94-420, + workers)
- For each file, write its parts in order: `chunk(guid).data[offset : offset+size]` appended to the file. A chunk can be shared across files and parts.
- legendary keeps a reference count per chunk GUID in RAM (shared memory, default 2 GiB max via `max_memory`). It evicts a chunk after its last use, and downloads each unique chunk only once, in first-use order.
- Simpler Swift plan:
  1. Walk the files sorted by lowercased name (as legendary does).
  2. Keep a bounded LRU/refcount cache of decoded chunks. Put chunks that are used more than once in an on-disk cache when RAM is tight.
  3. Download in parallel. legendary uses `min(cpu*2, 16)` workers. On retry it waits 0 s after the first failure and `2**(tries-1)` s after later ones, then requeues failed jobs.
- **Files with no chunk parts** are created empty. For symlinks, create the link. For flag `0x4`, chmod +x.
- **Case handling:** Windows games expect case-insensitive paths. legendary does case-insensitive lookup on non-Windows (`case_insensitive=platform.startswith('Win')`). APFS is usually case-insensitive, but case-sensitive volumes exist, so treat paths case-insensitively for Windows builds.
- **Disk space:** legendary computes `disk_space_delta` as the peak of added files plus changed files minus the old files they replace, and fails the install if free space is below it (`check_installation_conditions`).
- **Resume:** after each file closes, legendary appends `"{sha1hex}:{filename}\n"` to `{tmp}/{app}.resume`. On restart, it skips files whose recorded hash matches the manifest and which exist (`run_analysis`, lines 123-155; `manager.py`, lines 579-586).
- **Verify / repair** (`lfs/utils.py:validate_files`; `cli.py:verify_game`): SHA1 each file (1 MiB reads) against FML `hash`. The result is MATCH, MISMATCH or MISSING. Repair re-runs the download with only the bad files. A repair of a changed file downloads the whole file.

### 3f. Install tags / selective download (`run_analysis`, lines 172-188; `utils/selective_dl.py`)
- `file_install_tag` is a list of tags. A file is kept if any of its tags is in the list, or if `''` is in the list and the file has **no** tags.
- The other files are marked "unchanged" (skipped), and deletion tasks run for them when tags change.
- Tag definitions for the SDL prompt are hardcoded only for Fortnite and Cyberpunk (`Ginger`): language and voice packs. They are fetched from `https://api.legendary.gl/v1/sdl/{app}.json`.
- Most games have no tags. For v1, Playden can install everything (tags = all).

### 3g. Updates, deltas, patching
- **Update detection:** asset `buildVersion` != installed `version`.
- **Manifest comparison** (`ManifestComparison.create`, lines 996-1026): compare the filename sets and each file's SHA1 to get added, removed, changed and unchanged files.
- **Chunk reuse for changed files** (`run_analysis`, lines 300-323): if a new part `(guid, offset, size)` lies inside a part the old file already had, read those bytes from the old local file instead of downloading them.
  1. Write to `file.tmp`.
  2. Delete the old file and rename.
  3. Delete removed files at the end.
- **Delta manifests** (`core.py:get_delta_manifest`, lines 1468-1474): `GET {base_url}/Deltas/{new_build_id}/{old_build_id}.delta`. Non-200 means none exists; this is common. If one exists, `Manifest.apply_delta_manifest` (lines 244-277) replaces matching file entries and appends new chunks. This is optional and only an optimization.
- Save the manifest for each install (legendary saves `{app}_{platform}_{version}.manifest`). It is needed for patching, verify and uninstall (uninstall deletes the FML file list, not the whole directory).

### 3h. Swift port size estimate

| Component | Est. Swift LOC |
|---|---|
| HTTP API client (auth incl. device flow, assets, library, catalog, manifest API, exchange, ovt) + Codable models | 600–900 |
| Binary manifest parser (FString, header, Meta/CDL/FML/CF, encrypted section, chunk path) | 450–650 |
| JSON manifest parser | 120–180 |
| Chunk parser + zlib (Compression framework or libz) + AES-GCM (CryptoKit) | 120–200 |
| Download planner (comparison, tag filter, chunk refcount/cache plan, reuse for patching, disk delta) | 400–600 |
| Download/write engine (URLSession concurrency, retries, cache, resume file, progress, cancel) | 600–900 |
| Verify / repair / uninstall | 150–250 |
| Launch builder (args, exchange code, ovt, Wine integration) | 150–250 |
| **Total** | **~2,600–3,900** (plus tests: keep sample manifests and chunks as fixtures) |

---

## 4. Launch (`core.py:get_launch_parameters`, lines 830-936; `cli.py:launch_game`, lines 594-744)

**Command:** `[wrapper…] [wine] {install_path}/{executable} {game_parameters} {user_parameters} {egl_parameters}`. Working directory = the folder containing the exe.

- `executable` = manifest `meta.launch_exe`, with `\` changed to `/` and leading `/` removed. legendary replaces it with `get_exe_override(app_name)` if that file exists in the manifest (`utils/game_workarounds.py`; live list in `version.json` → `game_overrides.executable_override`, e.g. `kinglet` Civ VI → `Base/Binaries/Win64EOS/CivilizationVI.exe`). A user config `override_exe` can also replace it.
- `game_parameters`:
  1. `shlex.split(meta.launch_command, posix=False)`, stored as `InstalledGame.launch_parameters`
  2. then `shlex.split(customAttributes.AdditionalCommandLine)`
- Before launch, legendary logs in (refresh if needed) and checks that the asset `buildVersion` equals the installed version (`cli.py`, lines 628-644).
- **EGL parameters, in legendary's order:**
  ```
  -AUTH_LOGIN=unused
  -AUTH_PASSWORD=<exchange code>     # from GET /account/api/oauth/exchange, fetched right before launch (valid 300 s, single use); empty string when offline
  -AUTH_TYPE=exchangecode
  -epicapp=<appName>                 # for a launchable add-on: the add-on's app name, while running the base game's exe
  -epicenv=Prod
  [-epicovt=<path to .ovt>]          # only when OwnershipToken == "true" and online
  -EpicPortal
  -epicusername=<displayName>        # legendary passes it unquoted as a single argv element
  -epicuserid=<account_id>
  -epiclocale=<lang code, e.g. "en"> # config per game > CLI > system locale language part
  -epicsandboxid=<namespace>
  [-epicdeploymentid=<sidecar.config.deploymentId>]  # only if a sidecar exists
  ```
- **Ownership token** (`egs.py:get_ownership_token`, lines 156-163):
  `POST https://ecommerceintegration-public-service-ecomprod02.ol.epicgames.com/ecommerceintegration/api/public/platforms/EPIC/identities/{account_id}/ownershipToken` with bearer. The body is form-encoded `nsCatalogItemId={namespace}:{catalogItemId}`.
  - Write the **raw response bytes** to `{tmp}/{namespace}{catalogItemId}.ovt` and pass the path.
  - **Wine design question [UNVERIFIED]:** legendary passes the host path unchanged. A Unix path like `/Users/...` may not resolve for a Windows game running under Wine. Prefer writing the file inside the prefix (for example `drive_c/users/Public/…`) and passing a Windows path (`C:\…`), or use `Z:\Users\…`. Test with a Denuvo title.
- **Offline rules:**
  - When offline, the exchange code is empty and there is no ovt. legendary only **warns** when `CanRunOffline` is false, and does not block the launch.
  - Offline launch also skips the login and version check.
  - A per-game `offline=true` config forces offline mode.
  - Playden should launch offline only when the network or refresh fails, and warn when `can_run_offline` is false.
- **Wine / CrossOver specifics** (`core.py:get_app_launch_command` and `get_app_environment`; `lfs/crossover.py`; `lfs/eos.py`):
  - On non-Windows systems, legendary puts the wine binary before the exe.
    - On macOS it looks for CrossOver apps and uses `…/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine` with env `CX_BOTTLE=<bottle>` (default bottle `Legendary`), and unsets `WINEPREFIX` when CX is used.
    - Otherwise it uses `wine`, or `wine_executable` from config, with `WINEPREFIX`.
  - It sets no DXVK or other env itself; that is config `[app.env]` sections.
  - Native (non-`Win*`) installs launch with no wine.
- **EOS Overlay** (optional, `lfs/eos.py`):
  - It is an Epic app: `98bc04bc842e4906993fd6d6644ffb8d`, ns `302e5ede476149b1bc3e4fe6ae45e50e`, item `cc15684f44d849e89e9bf4cec0508b68`.
  - To enable it, install it and write `[Software\\Epic Games\\EOS]` `"OverlayPath"="Z:/path"` to the prefix's `user.reg`. legendary skips the Vulkan layer keys under Wine.
  - Games run fine **without** the overlay. It is only needed for the in-game friends/overlay UI, so skip it for v1.
  - EOSH (Epic Online Services Helper, the Windows service `c9e2eb9993a1496c99dc529b49a07339`) is only used by legendary's `activate`/ticket code. It is not needed.
- **Prerequisites:** manifest `prereq_ids/name/path/args` (e.g. VC++ or DirectX redists under `Installer/` in the game dir). legendary runs them only on Windows, and on Linux/macOS it prints "Automatic installation not available" (`cli.py:_handle_postinstall`). Under Wine, Playden may run `path args` inside the prefix once and record that it is installed.
- **Uninstaller:** manifest `uninstall_action_path/args` (data_version ≥ 2). It is optional.

---

## 5. Gotchas

- **Rate limits:** legendary has no explicit handling and no public numbers. Its observable behaviour:
  - up to 16 parallel metadata requests
  - 10 s timeouts
  - chunk retries with exponential backoff (`2**(tries-1)` s, `max_retries` default 7 in `DLWorker`)
  - metadata cached on disk and refreshed only on build or sidecar change
  Playden should do the same: cache catalog metadata and artwork, fetch assets on library refresh (not on every view), and back off on 429 or 5xx.
- **User agent:** use the EGL-style UA above. Epic has changed behaviour for old UAs before, which is why legendary fetches the version remotely. Make it configurable.
- **Client credential rotation:** legendary fetches `client_id`/`client_secret` from `api.legendary.gl`. Playden should also have a remote-config path, for the launcher client and the Switch device-code client.
- **corrective_action_required:** the user must accept terms on the web, so show `continuationUrl` as a QR code on the TV.
- **EOS / EAC / anti-cheat:**
  - legendary warns (Linux only) when installed files include `easyanticheat` (EAC), `beclient` (BattlEye), `equ8.dll` (EQU8) or `fna.dll`/`xna.dll` (`core.py:check_installation_conditions`, lines 1705-1760).
  - Under Wine on macOS, kernel-level or unsupported anti-cheat titles (Fortnite, many EAC/BattlEye multiplayer games) will not work. Flag them in the UI with the same filename heuristics.
  - Some EAC-EOS games list `EpicOnlineServicesInstaller`/EOSH prereqs. Those services are generally not needed for single-player under Wine.
- **Denuvo / ownership:** `OwnershipToken == "true"` means an ovt is needed and must be fetched online. Denuvo under Wine/CrossOver is hit or miss.
- **EA / Ubisoft titles:**
  - `ThirdPartyManagedApp`/`ThirdPartyManagedProvider` means not installable through Epic.
  - `partnerLinkType == "ubisoft"` titles have assets, but they need a Ubisoft account link and Ubisoft Connect. The `activate --uplay` flow uses store GraphQL (`models/gql.py`).
  - Some Ubisoft titles ship only a Uplay installer (detected by the exe-name heuristic in 2d).
  - Show all of these as unsupported in v1.
- **Encrypted (v22+/v24) manifests:** these are newer, and the keys arrive in the manifest API `secrets`. Preloads cannot be decrypted until release.
- **CDN tokens:** manifest URLs carry short-lived `cf_token`/`ak_token`/`f_token` query params. Do not store them; store only base URLs.
- **Game quirks:** a live list of exe overrides and "download order optimisation" games is in `version.json` (`game_overrides`). There are also per-game wiki tips (`game_wiki`). Playden can mirror the exe overrides.
- **macOS native builds (out of scope, brief):**
  - Use `platform=Mac` for assets and the manifest API.
  - The files are usually a `.app` bundle at the manifest root. legendary installs these into the base dir with no game folder, and treats non-`.app` Mac builds like Windows builds (`core.py:prepare_download`, lines 1577-1586).
  - Launch without wine (`launch_exe` points into `X.app/Contents/MacOS/…`).
  - Cloud saves use `CloudSaveFolder_MAC`.
  - If a Mac asset is missing, legendary falls back to Windows (`install_platform_fallback`).
