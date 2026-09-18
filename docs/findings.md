# Findings: Flutter web `--web-content-hash` red-team

Severity: **BLOCKER** ships broken users · **HIGH** stale or mixed app in a
common configuration · **MEDIUM** needs docs/tooling · **LOW** edge · **INFO**
confirmed-good behavior worth recording.

Targets: `master` = Phase 1 as shipped (`3.48.0-1.0.pre-742 @ 74db688fb6`);
`phase3` = `kevmoo:web-content-hash-phase-3` (Phases 1–3).

Every finding cites a scenario id; `dart run bin/redteam.dart --sdk <target> -s <id>`
reproduces it and writes the request-by-request evidence to `results/`.

---

## F1 · HIGH · `master` · Firebase-style rules leave assets stale for an hour → new code, old assets

**Scenario** S1.firebaseRules. Hosting rules exactly as
`flutter_web_cache_check fb-config` writes them (hashed entrypoints
`immutable`, bootloaders `no-cache`), with Firebase Hosting's default
`max-age=3600` for everything else.

**Observed** (second visit after an atomic v2 deploy): `index.html`,
`flutter_bootstrap.js` fetched fresh; `main.dart.5e21af80.js` (v2) loaded;
**every file under `assets/` — including `AssetManifest.bin.json` and
`FontManifest.json` — served from disk cache** (`cc=max-age=3600`). The app
reports `version=v2` while its assets are stamped `v1`.

**Why it matters** With Phase 1 only, `assets/**` are not hashed, so the
"correct" Phase 1 header setup still yields a mixed deploy for up to an hour:
new code reading old manifests/images/fonts/shaders. Any asset added in v2 is
missing from the cached manifest → runtime load failures.

**Recommendation**

- Docs + `fb-config`: until Phase 2 lands, `assets/**` (and `FontManifest.json`,
  `AssetManifest.*`, `NOTICES`, shaders) must be `no-cache` too; the current
  rule set only covers the bootloaders.
- Phase 2 fixes the _bytes_ (hashed asset names) but not the manifests
  themselves; the manifests must stay `no-cache`, which the `strict` policy
  models. Worth stating explicitly in the flag's help text / deployment docs.

## F2 · HIGH · `master` · Bare hosts (no `Cache-Control`) pin users to the old build via heuristic caching

**Scenario** S1.heuristic. No `Cache-Control` at all, `Last-Modified` present
(nginx/Apache/S3 defaults).

**Observed** Second visit: **origin received zero requests.** `index.html`,
`flutter_bootstrap.js`, `main.dart.<v1 hash>.js` and all assets came from disk
cache. User stays on v1 until heuristic freshness (10% of the resource's age
since `Last-Modified`) expires — days for a site that hasn't deployed
recently.

**Why it matters** Content hashing gives no benefit unless `index.html` and
`flutter_bootstrap.js` are explicitly revalidated; the flag's help text says
so, but a bare host silently fails the precondition and there is no signal at
build or run time.

**Recommendation** `flutter build web --web-content-hash` should print the
two-line hosting requirement every time (it currently does — see the build
output in `results/`), and `flutter_web_cache_check check` must fail on a
_missing_ `Cache-Control` for bootloaders (it does). Consider having the
loader itself fetch `flutter_bootstrap.js` with `cache: 'no-cache'` semantics
where possible (it is a `<script>` tag today, so this is a docs item).

## F3 · HIGH · `master` · `index.html` fresh but `flutter_bootstrap.js` cached = old app forever, no 404

**Scenario** S1.bootstrapCached.

**Observed** `index.html` re-fetched (v2), `flutter_bootstrap.js` from cache
(v1) → loads `main.dart.<v1 hash>.js` from cache → app is v1. No failed
request, no console error, nothing for a user to notice. Because the v1
entrypoint was cached `immutable`, the missing origin file never matters.

**Why it matters** A very common partial misconfiguration (only `*.html` gets
`no-cache` in many CDN presets). The failure is silent and permanent until
cache eviction.

**Recommendation** Docs must name `flutter_bootstrap.js` explicitly as a
must-revalidate file (they do in the flag help; hosting guides should too).
`flutter_web_cache_check check` covers this case (it HEADs
`flutter_bootstrap.js`).

## F4 · INFO · `master` · Correct headers work

**Scenario** S1.strict (hashed files `immutable`, every unhashed file
`no-cache`). All three visits correct; second visit re-fetched only
`index.html` + `flutter_bootstrap.js` + the new entrypoint; assets revalidated
with `304`s.

## F5 · INFO · `master` · Everything-immutable misconfiguration is unrecoverable

**Scenario** S1.cacheEverything. Origin not contacted at all on later visits;
v1 forever. Expected, but it is the blast radius for "I turned on the flag and
set `immutable` on `**`."

## F6 · INFO · `master` · Firebase Hosting with no header rules: one-hour stale window, but consistent

**Scenario** S1.firebaseDefaults (`max-age=3600` on everything). Second and
third visits fully from cache → v1 (consistent, not mixed) for an hour. The
edge case not observable in this run: when `index.html` and
`flutter_bootstrap.js` expire at different moments, the new index + old
bootstrap → old hash which no longer exists at origin → blank screen. See S2
for the analogous window.

## F7 · BLOCKER · `phase3` · Every non-manifest asset API 404s once assets are hashed

**Scenario** any `phase3` load; clearest in S1.strict **first visit** (fresh
profile, nothing cached — this is not a caching bug, it is the feature).
Also S3/S14 (`lazy.raw.txt`, `lazy.deployStamp`, `lazy.url.txt`).

**Observed** 12 of 21 probes fail on first load:

| API path                                                                                                                                      | Result                                                                                              |
| :-------------------------------------------------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------- |
| `AssetImage` / `Image.asset` (png, jpg, gif, webp, bmp, `package:`)                                                                           | ✅ resolves via `AssetManifest` to `logo.342887cc.png`, `2.0x/logo.8f629ad9.png`                    |
| fonts declared in `pubspec.yaml`                                                                                                              | ✅ `FontManifest.json` rewritten to `AdwaitaMono-Bold.6378ff11.ttf`                                 |
| `FragmentProgram.fromAsset('shaders/simple.frag')`                                                                                            | ✅ shaders are excluded from hashing                                                                |
| `rootBundle.load` / `loadString` with a raw key — json, txt, bin, directory-wildcard file, `packages/sample_pkg/…` text, a png, the font file | ❌ `Unable to load asset: "assets/data/config.json"` → `GET assets/assets/data/config.json` **404** |
| `vector_graphics` `AssetBytesLoader('assets/svg/icon.svg')` (transformer output)                                                              | ❌ 404                                                                                              |
| `ui_web.assetManager.getAssetUrl(key)` + fetch (what `video_player_web`, audio, and other plugins do)                                         | ❌ 404                                                                                              |

On disk: `assets/assets/data/config.53e706a7.json`. In
`AssetManifest.bin.json`: `assets/data/config.json → assets/data/config.53e706a7.json`.
`rootBundle.load(key)` goes straight to `ui_web.assetManager.load(key)` and
never consults the manifest.

**Why it matters** `rootBundle.loadString('assets/config.json')`,
`flutter_svg`, `lottie`, `rive`, `google_fonts` (asset mode),
`video_player_web`, `audioplayers`, localization JSON loaders — a very large
share of real apps load _something_ by raw key. With Phase 2 as-is, turning on
`--web-content-hash` breaks them on the **first** load, for every user, with
no build-time signal. #191919's description defers this to "a companion
framework task"; Phase 3 (#192953) un-hides the flag before that task exists.

**Recommendation**

- Do **not** un-hide the flag (Phase 3) until raw-key loads resolve through
  the manifest. Options: (a) `PlatformAssetBundle.load` on web consults the
  `AssetManifest` (key → hashed variant, scale 1.0) before hitting the
  network; (b) the engine's `assetManager.getAssetUrl` does the same lookup;
  (c) _also_ emit an unhashed copy of every asset (defeats caching for those
  files but keeps apps working) — a poor fallback.
- Independently of (a)/(b): build-time detection is impossible in general,
  so the tool should at least warn that raw-key asset loads and plugins using
  `assetManager.getAssetUrl` are unsupported, the way it errors for deferred
  imports and legacy `index.html`.
- The `precache_manifest.json` work is fine; it is the runtime resolution
  that is missing.

## F8 · HIGH · both · Deploy under an open tab: old code loads new assets (`master`) or 404s (`phase3`)

**Scenario** S3, S14. Tab open on v1; atomic v2 deploy; the v1 app then
lazily loads assets it hadn't touched.

**Observed**

- `master`: `lazy.deployStamp` returned **`v2`** inside the v1 app — asset
  URLs are stable, so old code reads whatever is on the server now, with no
  error. Mixed-version state (new JSON schema / image / manifest for old
  code).
- `phase3`: the old code's manifest names `assets/lazy/deploy.2d27fbdf.txt`;
  that file no longer exists → `Unable to load asset` **404** for the rest
  of the session. Unchanged assets (same hash) still load.

**Why it matters** Neither behavior is handled and the app gets no signal
that a newer deploy exists (`version.json` is only read at boot).

**Recommendation** Document it; recommend keeping the previous build's
hashed files on the host for a grace period (overlay deploys rather than
atomic replace — S2's `deployOverlay` shows this works) and consider a
framework hook to detect a version change.

## F9 · MEDIUM · `master` · Non-atomic uploads: a window of blank pages, recoverable only if 404s aren't cached

**Scenario** S2.strict (shell uploaded before the new entrypoint).

**Observed** During the window the new `flutter_bootstrap.js` references
`main.dart.5e21af80.js`, which doesn't exist yet → 404 → blank page (no
fallback, no retry, console shows the 404). Once the upload completes the
next load works — _provided_ the host answered the 404 with `no-cache`.
S2.strict.negcache models a CDN that caches 404s for 5 minutes: after the
upload completed, the browser kept serving the cached 404 for
`main.dart.<hash>.js` and the page stayed blank (`no window.__redteam.done`,
`main.dart.5e21af80.js → 404` from cache). With `no-cache` on 404s the very
next load recovered.

**Recommendation** Deployment docs: upload hashed files first, shell last
(or use a host with atomic releases), and make sure 404s are never served
with the hashed-file cache rule.

## F10 · INFO · `master` · A stale CDN `index.html` is harmless as long as `flutter_bootstrap.js` is fresh

**Scenario** S6: edge keeps serving v1 `index.html` for 60 s after an atomic
v2 deploy. The app still boots as v2 because `index.html` only references
`flutter_bootstrap.js`, which carries the hash. Good design property worth
stating in docs: the only file that _must_ revalidate is `flutter_bootstrap.js`
(and `index.html` only if it inlines the bootstrap).

## F11 · INFO · `master` · Tool refuses legacy `index.html` and deferred imports

**Scenario** S10, S11. A custom `index.html` with `<script src="main.dart.js">`
fails the build with a clear message naming `flutter_bootstrap.js` and
`flutter create . --platforms web`. Deferred imports are rejected with an
explicit error. Both are the right call (a warning would have shipped blank
pages).

## F12 · INFO · `master` · Incremental rebuilds do not leave stale hashed files

**Scenario** S13: a second `flutter build web` in the same directory produced
only the new hash; the previous `main.dart.<hash>.js` was removed.

## F13 · MEDIUM · `master` · `flutter_web_cache_check` passes a configuration that yields mixed versions

**Scenario** S15 + F1. The checker returns success for the `firebaseRules`
policy (its own `fb-config` output), which on Phase 1 leaves `assets/**`
and both manifests cached for an hour → new code, old assets. It only
inspects `index.html`, `flutter_bootstrap.js`, and the entrypoints.

**Recommendation** `check` should HEAD `assets/AssetManifest.bin.json` and
`assets/FontManifest.json` (must revalidate) and, until Phase 2 ships, warn
that unhashed `assets/**` need `no-cache` too; `fb-config` should write that
rule. Its immutable test also accepts any `max-age=` (e.g. `3600`) as
"aggressively cached" — tighten to `immutable` or `max-age≥1y`.

## F14 · INFO (with a caveat) · `master` · Migration off the legacy offline-first service worker works — after one stale render

**Scenario** S5.strict. v1 built without the flag and with the pre-#176834
worker + the old bootstrap (`serviceWorkerUrl` set, so it installs); visited
twice so the worker serves the whole shell; then v2 (hashed, stub worker)
deployed atomically.

**Observed**

- Visit 2: `index.html`, `flutter_bootstrap.js`, `main.dart.js`, manifests,
  fonts — everything — `source=service-worker`.
- Visit 3 (v2 live): **first render is v1**, served entirely by the old
  worker. The old bootstrap re-registers its own `?v=` URL, the browser
  fetches the script (top-level worker scripts bypass the HTTP cache by
  default), gets the stub, installs it (`2 installing → installed`), the stub
  unregisters and `navigate()`s the client, and the page reloads as **v2**
  from the network. ~10–25 s end to end, one visible flash of the old app.
- Visit 4: no worker registered; v2; hashed entrypoint from disk cache.

**Caveat** This works only because today's loader still calls
`serviceWorker.register(...)` when a registration _already exists_
(`getRegistration().then(r => r ? register() : skip)`) and the default
bootstrap still passes `serviceWorkerSettings`. If either is removed before
every legacy worker has been replaced, users with the old worker are pinned
to the old app until the browser's own 24 h update check. Keep both until
#156910 closes.

## F15 · INFO · `master` · `--pwa-strategy none` registers nothing

**Scenario** S9. No same-origin worker appears in either visit; upgrade
behaves like S1.strict. (The flag is deprecated and hidden from `--help`.)

## F16 · INFO · `master`/`phase3` · Fresh visitors never get a service worker

Observed in every scenario: with the default bootstrap, a first-time visitor
has no service worker at all (the loader only updates pre-existing
registrations). Consequence: the HTTP cache policy is the _only_ caching
layer that matters for new users, which is what makes F1–F3 as severe as they
are.

## F17 · HIGH · `phase3` · Cached manifests defeat hashed assets: v2 code with v1 manifests and v1 assets, plus 404s for anything not yet cached

**Scenario** S1.firebaseRules on `phase3` (assets hashed; `fb-config` rules;
Firebase default `max-age=3600` on `assets/**`).

**Observed** Second visit after the v2 deploy (v2 changed the logo, so its
hash changed): code is v2, but `AssetManifest.bin.json` and
`FontManifest.json` came from disk cache (v1) → the app resolved
`assets/images/2.0x/logo.010094bb.png` (the **v1** hash, served from the
immutable disk cache even though the file is gone at origin) and
`resolved.deployStamp = v1`. Everything the user saw on visit 1 stays v1;
anything the v1 manifest names that the browser had _not_ cached would 404
(see S3 on `phase3`). Under `strict` (manifests `no-cache`) the same visit
resolved `logo.cdd74878.png` (v2) and the stamp read `v2`.

**Why it matters** Phase 2 moves the version-coupling from the asset bytes
into the two manifests. Hosting guidance and `fb-config` must treat
`assets/AssetManifest.bin.json`, `assets/AssetManifest.bin`,
`assets/FontManifest.json` (and `NOTICES`, shaders — anything left unhashed)
exactly like `flutter_bootstrap.js`: `no-cache`. Today's rules don't, and
`flutter_web_cache_check check` doesn't look at them (F13).

**Recommendation** Same as F1/F13, now mandatory rather than "until Phase 2
lands": bootloader rule set = `index.html`, `flutter_bootstrap.js`,
`flutter.js`, `version.json`, `manifest.json`, `precache_manifest.json`,
**and the asset manifests**. Alternatively hash the manifests too and
reference them from `flutter_bootstrap.js` (the loader already knows the
build config).

## F18 · INFO · `phase3` · `precache_manifest.json` is accurate

**Scenario** S12 on `phase3`: every entry resolves, hash and size match the
bytes, `urlHashed` is correct for all entries, and every runtime file
(minus source maps, symbols, dotfiles, the worker, the manifest itself,
`canvaskit/`) is listed. Incremental rebuilds (S13) match a clean build.

---

## F19 · MEDIUM · `master` · Legacy-worker migration under Firebase default headers: worker gone, user still on v1 for the bootstrap's max-age

**Scenario** S5.firebaseDefaults (same as F14 but `max-age=3600` on
everything).

**Observed** Visit 3: the stub installs, the legacy worker goes `redundant`,
the client is navigated — and the reload serves `flutter_bootstrap.js` and
`main.dart.js` from the **HTTP disk cache** (v1, `max-age=3600`). Visit 4:
no worker controls the page, the cached v1 bootstrap registers
`flutter_service_worker.js?v=<old>` again, the stub installs and unregisters
itself again (worker versions 4 → 5), but does **not** navigate (it only
navigates clients it controls, and a fresh registration controls nothing),
so there is no reload loop — measured: 1 navigation in 10 s. The user sees
v1 until the bootstrap's cache entry expires.

**Why it matters** For an app upgrading across #176834 on default Firebase
headers, the worker cleanup works but buys nothing for an hour; every visit
in that hour pays an install/unregister cycle. Compare S5.strict, where the
same migration lands v2 on visit 3.

**Recommendation** Nothing new beyond F1/F3: `flutter_bootstrap.js` must be
`no-cache`, and deployment docs for the worker removal should say so
explicitly, because "the worker is gone" reads like "users are on the new
build" and here it isn't.

_Full evidence: `results/full/` (both targets, all scenarios). S5.firebaseDefaults: see `results/s5/`._
