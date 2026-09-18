# sample_app

Fixture for the red-team harness. Loads one of every asset type through
every API path and publishes `window.__redteamJson` (see `lib/main.dart`).
`lib/main_deferred.dart` is the deferred-import variant. `variants/` holds
per-version images the harness swaps in before building.

Build it by hand to poke at the output:

```sh
flutter build web --web-content-hash --dart-define=APP_VERSION=v1
```
