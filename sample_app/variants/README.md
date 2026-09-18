# Per-version image fixtures

The harness copies `variants/<version>/` over `assets/images/` before each
build so v1 and v2 differ in an image (and therefore in its content hash),
not only in code and text assets. Unknown versions fall back to `v1`.
