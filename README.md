# flutter_web_cache_redteam

Empirical stress tests for Flutter web's `--web-content-hash` feature
([flutter/flutter#149031](https://github.com/flutter/flutter/issues/149031):
Phase 1 [#190153](https://github.com/flutter/flutter/pull/190153), Phase 2
[#191919](https://github.com/flutter/flutter/pull/191919), Phase 3
[#192953](https://github.com/flutter/flutter/pull/192953)).

The question this repo answers is not "does the build produce hashed files"
but **"what does a real browser show a real user across real deploys"** —
including the misconfigured hosts, half-finished uploads, CDN edges, and
already-installed service workers that exist in the wild.

Findings live in [docs/findings.md](docs/findings.md).

## Layout

- `sample_app/` — a Flutter web app that loads **one of every asset type**
  through **every API path** (manifest-resolved `AssetImage`, raw
  `rootBundle` keys, `ui_web.assetManager.getAssetUrl`, `FragmentProgram`,
  a `vector_graphics` transformer, a package asset, a directory wildcard,
  resolution variants, a custom font) and publishes what it got to
  `window.__redteamJson`. `window.__redteamLoadLazy()` loads a second set on
  demand so a deploy can happen underneath an open tab.
- `sample_pkg/` — a path dependency that ships its own assets.
- `harness/` — Dart package:
  - `Builder` builds `sample_app` with a chosen Flutter checkout and options
    (`--web-content-hash`, `--wasm`, `--base-href`, `--pwa-strategy`, custom
    `index.html`/`flutter_bootstrap.js`, or the pre-3.38 offline-first service
    worker injected from git history).
  - `HostingServer` is a local stand-in for a static host: pluggable
    `Cache-Control` policies (heuristic, Firebase defaults, Firebase + the
    `fb-config` rules, strict, cache-everything, bootstrap-cached), `ETag`/304
    revalidation, and deploy strategies (atomic swap, overlay without delete,
    partial upload, delete-old-hashes, CDN-stale-`index.html`).
  - `ChromeSession` drives headless Chromium over CDP with a persistent
    profile (= a returning user's disk cache + service workers) and records
    every request's source (network / 304 / disk cache / memory cache /
    service worker / failed), console errors, and service worker lifecycle.
  - `scenarios.dart` — the matrix. `results/<timestamp>/summary.md` +
    `results.json` carry the evidence.

## Running

Prerequisites: a Flutter checkout at `~/github/flutter` (`master`) and
optionally the Phase 3 branch worktree at
`~/github/_flutter-web-content-hash-phase-3` (override with
`REDTEAM_FLUTTER_MASTER` / `REDTEAM_FLUTTER_PHASE3`); a Chromium (Playwright's
download under `~/.cache/ms-playwright` is found automatically, or set
`REDTEAM_CHROME`).

```sh
cd harness
dart pub get
dart run bin/redteam.dart --list
dart run bin/redteam.dart --sdk master --sdk phase3          # everything
dart run bin/redteam.dart --sdk master -s S1 -s S5 --headed  # a subset, with a window
```

Each scenario builds what it needs (builds are cached per SDK + options for
the run under `--work`, default `/tmp/redteam_work`), deploys to a fresh local
host, and drives a fresh or warm browser profile as the scenario dictates.
