// Variant entrypoint with a deferred import, to observe what
// `--web-content-hash` does with deferred part files.
import 'package:flutter/material.dart';

import 'deferred_lib.dart' deferred as deferred;
import 'main.dart' as base;

void main() {
  base.main();
  deferred.loadLibrary().then((_) => debugPrint(deferred.deferredGreeting()));
}
