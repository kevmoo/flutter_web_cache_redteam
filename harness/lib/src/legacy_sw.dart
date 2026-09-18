import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The offline-first service worker every Flutter web app shipped before
/// flutter/flutter#176834 (Oct 2025). Users who visited such an app still
/// have it installed; a new deploy has to migrate them off it.
final String legacyServiceWorkerTemplate = File(
  p.join(_packageRoot(), 'lib', 'src', 'legacy_sw_template.js'),
).readAsStringSync();

String _packageRoot() {
  // Resolve relative to this file so it works from any working directory.
  final uri = Platform.script;
  var dir = Directory(p.dirname(uri.toFilePath()));
  while (!File(p.join(dir.path, 'pubspec.yaml')).existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'Cannot locate harness pubspec.yaml from ${uri.toFilePath()}',
      );
    }
    dir = parent;
  }
  return dir.path;
}

/// Rewrites `flutter_service_worker.js` in [build] with the legacy worker,
/// populated exactly as the old `WebServiceWorker` target did: md5 of every
/// output file (minus source maps), `/` aliased to `index.html`, and the app
/// shell as `CORE`.
void injectLegacyServiceWorker(Directory build) {
  final resources = <String, String>{};
  for (final file in build.listSync(recursive: true).whereType<File>()) {
    final rel = p.posix.joinAll(
      p.split(p.relative(file.path, from: build.path)),
    );
    if (rel.endsWith('.map') || rel == 'flutter_service_worker.js') continue;
    final hash = md5.convert(file.readAsBytesSync()).toString();
    resources[rel] = hash;
    if (rel == 'index.html') resources['/'] = hash;
  }
  final entry = resources.keys.firstWhere(
    (k) => RegExp(r'^main\.dart(\.[a-f0-9]{8})?\.js$').hasMatch(k),
    orElse: () => 'main.dart.js',
  );
  final core = <String>[
    entry,
    'index.html',
    'flutter_bootstrap.js',
    'assets/AssetManifest.bin.json',
    'assets/FontManifest.json',
  ];
  final js = legacyServiceWorkerTemplate
      .replaceFirst(
        r'$$RESOURCES_MAP',
        const JsonEncoder.withIndent('  ').convert(resources),
      )
      .replaceFirst(r'$$CORE_LIST', json.encode(core));
  File(p.join(build.path, 'flutter_service_worker.js')).writeAsStringSync(js);
}
