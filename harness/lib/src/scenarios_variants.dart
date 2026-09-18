import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'builder.dart';
import 'hosting.dart';
import 'scenario.dart';

/// Build-variant and Phase 3 scenarios (S7–S14).
List<Scenario> variantScenarios() => <Scenario>[
  VariantUpgradeScenario(
    'S7',
    'wasm build (main.dart.<hash>.wasm/.mjs)',
    const BuildOptions(version: 'v1', wasm: true),
    const BuildOptions(version: 'v2', wasm: true),
  ),
  VariantUpgradeScenario(
    'S8',
    'base-href /app/',
    const BuildOptions(version: 'v1', baseHref: '/app/'),
    const BuildOptions(version: 'v2', baseHref: '/app/'),
    basePath: '/app/',
  ),
  VariantUpgradeScenario(
    'S9',
    '--pwa-strategy none (no service worker at all)',
    const BuildOptions(version: 'v1', pwaStrategy: 'none'),
    const BuildOptions(version: 'v2', pwaStrategy: 'none'),
    expectNoServiceWorker: true,
  ),
  CustomIndexScenario(),
  DeferredImportScenario(),
  PrecacheManifestScenario(),
  IncrementalRebuildScenario(),
  TwoTabScenario(),
  CacheCheckDogfoodScenario(),
];

/// Generic warm upgrade under strict headers for a build variant.
class VariantUpgradeScenario extends Scenario {
  VariantUpgradeScenario(
    this.id,
    this.title,
    this.v1,
    this.v2, {
    this.basePath = '/',
    this.expectNoServiceWorker = false,
  });

  @override
  final String id;
  @override
  final String title;
  final BuildOptions v1;
  final BuildOptions v2;
  final String basePath;
  final bool expectNoServiceWorker;

  @override
  String get description =>
      'v1 first visit, atomic v2 deploy, warm second visit; strict headers.';

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final b1 = await ctx.build(v1);
    final b2 = await ctx.build(v2);
    result.builds.addAll([b1.toJson(), b2.toJson()]);
    if (!b1.succeeded || !b2.succeeded) {
      result.error = 'build failed: ${b1.stderr}\n${b2.stderr}';
      return;
    }
    final host = await ctx.host(HeaderPolicy.strict, basePath: basePath);
    final profile = ctx.freshProfile(id);
    try {
      await host.deployAtomic(b1.outDir);
      var chrome = await ctx.chrome(profile);
      var step = result.step('first visit (v1)');
      var report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v1');
      step.notes.add('entrypoints: ${b1.entrypoints().join(', ')}');
      step.notes.add(requestSources(chrome));
      if (expectNoServiceWorker) {
        await chrome.settle();
        step.check(
          'no service worker registered',
          chrome.serviceWorkers.isEmpty,
          chrome.serviceWorkerEvents.join(' | '),
        );
      }
      await chrome.close();

      await host.deployAtomic(b2.outDir);
      chrome = await ctx.chrome(profile);
      step = result.step('second visit after v2 deploy');
      report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v2');
      step.notes.add(requestSources(chrome));
      await chrome.close();
    } finally {
      await host.stop();
    }
  }
}

/// S10: a hand-written `index.html` that still references `main.dart.js`
/// directly (the documented incompatibility). What does the user see, and
/// did the tool say anything?
class CustomIndexScenario extends Scenario {
  @override
  String get id => 'S10';
  @override
  String get title => 'custom index.html referencing main.dart.js directly';
  @override
  String get description =>
      'Build with --web-content-hash and a legacy index.html; check tool output and the resulting page.';

  static const String legacyIndex = '''
<!DOCTYPE html>
<html>
<head>
  <base href="\$FLUTTER_BASE_HREF">
  <meta charset="UTF-8">
  <title>legacy index</title>
</head>
<body>
  <script src="main.dart.js" type="application/javascript"></script>
</body>
</html>
''';

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final b = await ctx.build(
      const BuildOptions(version: 'v1', customIndexHtml: legacyIndex),
    );
    result.builds.add(b.toJson());
    final step = result.step('build');
    step.check('build succeeded', b.succeeded, b.stderr.trim());
    final warned = RegExp(
      r'main\.dart\.js|content.hash|not supported|deprecated',
      caseSensitive: false,
    ).hasMatch('${b.stdout}\n${b.stderr}');
    step.check(
      'tool warned about the incompatible index.html',
      warned,
      'stdout/stderr had no mention; tail: ${b.stdout.trim().split('\n').reversed.take(3).join(' / ')}',
    );
    if (!b.succeeded) return;

    final host = await ctx.host(HeaderPolicy.strict);
    final profile = ctx.freshProfile(id);
    try {
      await host.deployAtomic(b.outDir);
      final chrome = await ctx.chrome(profile);
      final load = result.step('load the page');
      final report = await loadAndCapture(
        load,
        chrome,
        host,
        host.baseUri,
        timeout: const Duration(seconds: 15),
      );
      load.check(
        'app booted',
        report != null,
        report == null ? 'blank page' : 'version ${report['version']}',
      );
      load.notes.add(requestSources(chrome));
      load.notes.add('live entrypoints: ${b.entrypoints().join(', ')}');
      await chrome.close();
    } finally {
      await host.stop();
    }
  }
}

/// S11: deferred imports are documented as unsupported; confirm the tool
/// refuses loudly rather than shipping unhashed part files.
class DeferredImportScenario extends Scenario {
  @override
  String get id => 'S11';
  @override
  String get title => 'deferred import + --web-content-hash';
  @override
  String get description =>
      'Build lib/main_deferred.dart with and without the flag.';

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final without = await ctx.build(
      const BuildOptions(
        version: 'v1',
        contentHash: false,
        target: 'lib/main_deferred.dart',
      ),
    );
    final with_ = await ctx.build(
      const BuildOptions(version: 'v1', target: 'lib/main_deferred.dart'),
    );
    result.builds.addAll([without.toJson(), with_.toJson()]);

    final baseline = result.step('without the flag (baseline)');
    baseline.check('build succeeded', without.succeeded, without.stderr.trim());
    if (without.succeeded) {
      final parts = without.outDir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where((n) => n.contains('.part.js'))
          .toList();
      baseline.notes.add('part files: ${parts.join(', ')}');
    }

    final flagged = result.step('with --web-content-hash');
    flagged.check(
      'tool refuses (documented: not supported with deferred imports)',
      !with_.succeeded,
      with_.succeeded
          ? 'built successfully: ${with_.entrypoints().join(', ')}'
          : 'exit ${with_.exitCode}',
    );
    final message = '${with_.stdout}\n${with_.stderr}';
    flagged.check(
      'error message names deferred imports',
      RegExp(r'deferred', caseSensitive: false).hasMatch(message),
      message
          .trim()
          .split('\n')
          .where((l) => l.contains('deferred'))
          .take(2)
          .join(' / '),
    );
    if (with_.succeeded) {
      final parts = with_.outDir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where((n) => n.contains('.part.js'))
          .toList();
      flagged.notes.add('UNHASHED part files shipped: ${parts.join(', ')}');
    }
  }
}

/// S12: Phase 3's `precache_manifest.json` must describe reality.
class PrecacheManifestScenario extends Scenario {
  @override
  String get id => 'S12';
  @override
  String get title => 'precache_manifest.json vs the actual build output';
  @override
  String get description =>
      'Every entry resolves, hash+size match the bytes, urlHashed is right, and every runtime file is listed.';

  static const Set<String> _expectedExcluded = {
    'flutter_service_worker.js',
    'precache_manifest.json',
  };

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final b = await ctx.build(const BuildOptions(version: 'v1'));
    result.builds.add(b.toJson());
    if (!b.succeeded) {
      result.error = 'build failed';
      return;
    }
    final manifestFile = File(p.join(b.outDir.path, 'precache_manifest.json'));
    final step = result.step('manifest');
    if (!manifestFile.existsSync()) {
      step.notes.add(
        'no precache_manifest.json in this SDK (expected on master; Phase 3 adds it)',
      );
      return;
    }
    final manifest =
        json.decode(manifestFile.readAsStringSync()) as Map<String, Object?>;
    final entries = (manifest['entries'] as List<Object?>)
        .cast<Map<String, Object?>>();
    step.check('version is 1', manifest['version'] == 1);
    final urls = entries.map((e) => e['url'] as String).toList();
    step.check(
      'sorted by url',
      urls.join('\n') == ([...urls]..sort()).join('\n'),
    );

    final host = await ctx.host(HeaderPolicy.strict);
    try {
      await host.deployAtomic(b.outDir);
      final mismatches = <String>[];
      final badUrlHashed = <String>[];
      for (final e in entries) {
        final url = e['url'] as String;
        final resp = await http.get(host.baseUri.resolve(url));
        if (resp.statusCode != 200) {
          mismatches.add('$url → ${resp.statusCode}');
          continue;
        }
        final hash = sha256.convert(resp.bodyBytes).toString().substring(0, 8);
        if (hash != e['hash'] || resp.bodyBytes.length != e['size']) {
          mismatches.add(
            '$url hash ${e['hash']}≠$hash or size ${e['size']}≠${resp.bodyBytes.length}',
          );
        }
        final base = p.posix.basename(url);
        final actuallyHashed =
            base.contains('.$hash.') || base.endsWith('.$hash');
        if (actuallyHashed != (e['urlHashed'] == true)) {
          badUrlHashed.add('$url urlHashed=${e['urlHashed']}');
        }
      }
      step.check(
        'every entry resolves with matching hash and size',
        mismatches.isEmpty,
        mismatches.take(6).join(' | '),
      );
      step.check(
        'urlHashed is accurate',
        badUrlHashed.isEmpty,
        badUrlHashed.take(6).join(' | '),
      );

      final live = host
          .liveFiles()
          .map((f) => p.posix.joinAll(p.split(f)))
          .where(
            (f) =>
                !f.startsWith('canvaskit/') &&
                !f.startsWith('.') &&
                !f.endsWith('.map') &&
                !f.endsWith('.symbols') &&
                !f.endsWith('.info.json') &&
                !_expectedExcluded.contains(f),
          )
          .toSet();
      final missing = live.difference(urls.toSet());
      step.check(
        'every runtime file is listed',
        missing.isEmpty,
        'missing: ${missing.take(8).join(', ')}',
      );
      step.notes.add(
        '${entries.length} entries; hashed: ${entries.where((e) => e['urlHashed'] == true).length}',
      );
    } finally {
      await host.stop();
    }
  }
}

/// S13: build v1 then v2 in the same project directory (what developers do):
/// does the v2 output still contain v1's hashed files?
class IncrementalRebuildScenario extends Scenario {
  @override
  String get id => 'S13';
  @override
  String get title => 'incremental rebuild leaves no stale hashed files';
  @override
  String get description =>
      'Second `flutter build web` in the same directory; compare output trees.';

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final v1 = await ctx.build(const BuildOptions(version: 'incr1'));
    if (!v1.succeeded) {
      result.error = 'v1 build failed';
      return;
    }
    final v1Files = v1.fileHashes().keys.toSet();
    final v2 = await ctx.builder.build(
      ctx.sdk,
      const BuildOptions(version: 'incr2'),
      incrementalFrom: v1,
    );
    result.builds.addAll([v1.toJson(), v2.toJson()]);
    final step = result.step('compare');
    step.check('v2 build succeeded', v2.succeeded, v2.stderr.trim());
    if (!v2.succeeded) return;
    final v2Files = v2.fileHashes().keys.toSet();
    final hashed = RegExp(r'\.[a-f0-9]{8}(\.|$)');
    final stale = v1Files.difference(v2Files).where(hashed.hasMatch).toList();
    // Files present in v2's output dir that carry a hash from v1.
    final leftover = v2Files
        .where((f) => hashed.hasMatch(f) && v1Files.contains(f))
        .toList();
    step.notes.add(
      'v1 hashed files: ${v1Files.where(hashed.hasMatch).join(', ')}',
    );
    step.notes.add(
      'v2 hashed files: ${v2Files.where(hashed.hasMatch).join(', ')}',
    );
    step.check(
      'no v1 hashed file survives in the v2 output',
      leftover.isEmpty,
      'leftover: ${leftover.join(', ')}',
    );
    step.notes.add('removed from v1→v2: ${stale.join(', ')}');
  }
}

/// S14: two tabs on the same profile straddling a deploy.
class TwoTabScenario extends Scenario {
  @override
  String get id => 'S14';
  @override
  String get title => 'two tabs: one opened before the deploy, one after';
  @override
  String get description =>
      'Tab A on v1; deploy v2; tab B opens; tab A loads lazy assets.';

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final v1 = await ctx.build(const BuildOptions(version: 'v1'));
    final v2 = await ctx.build(const BuildOptions(version: 'v2'));
    result.builds.addAll([v1.toJson(), v2.toJson()]);
    if (!v1.succeeded || !v2.succeeded) {
      result.error = 'build failed';
      return;
    }
    final host = await ctx.host(HeaderPolicy.strict);
    final profile = ctx.freshProfile(id);
    try {
      await host.deployAtomic(v1.outDir);
      final tabA = await ctx.chrome(profile);
      var step = result.step('tab A on v1');
      var report = await loadAndCapture(step, tabA, host, host.baseUri);
      checkHealthyLoad(step, tabA, report, expectedVersion: 'v1');

      await host.deployAtomic(v2.outDir);
      final tabB = await tabA.openTab(host.baseUri.toString());
      step = result.step('tab B opened after v2 deploy');
      host.log.clear();
      report = await tabB.waitForAppReport();
      step.capture(tabB, host, report);
      checkHealthyLoad(step, tabB, report, expectedVersion: 'v2');
      step.notes.add(requestSources(tabB));

      step = result.step('tab A (still v1) loads lazy assets');
      tabA.resetObservations();
      host.log.clear();
      report = await tabA.triggerLazyLoad();
      step.capture(tabA, host, report);
      final lazy = (report?['lazyAssets'] as Map<String, Object?>?) ?? const {};
      final failed = lazy.entries
          .where((e) => (e.value as Map<String, Object?>)['ok'] != true)
          .map((e) => e.key)
          .toList();
      step.check('tab A lazy assets loaded', failed.isEmpty, failed.join(', '));
      final stamp =
          (lazy['lazy.deployStamp'] as Map<String, Object?>?)?['detail'];
      step.check(
        'tab A got v1 asset bytes',
        stamp == 'v1',
        'old code got assets stamped "$stamp"',
      );
      await tabA.close();
    } finally {
      await host.stop();
    }
  }
}

/// S15: does `flutter_web_cache_check check` flag each hosting policy the
/// way a user would need it to?
class CacheCheckDogfoodScenario extends Scenario {
  @override
  String get id => 'S15';
  @override
  String get title => 'flutter_web_cache_check verdicts per hosting policy';
  @override
  String get description =>
      'Runs the checker against a hashed v1 deploy under every HeaderPolicy.';

  static Directory _checkerDir() => Directory(
    Platform.environment['REDTEAM_CACHE_CHECK'] ??
        p.join(
          Platform.environment['HOME'] ?? '',
          'github',
          'kevmoo',
          'flutter_web_cache_check',
        ),
  );

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final checker = _checkerDir();
    if (!File(p.join(checker.path, 'bin', 'flutter_web_cache_check.dart'))
        .existsSync()) {
      result.error = 'flutter_web_cache_check not found at ${checker.path}';
      return;
    }
    final b = await ctx.build(const BuildOptions(version: 'v1'));
    result.builds.add(b.toJson());
    if (!b.succeeded) {
      result.error = 'build failed';
      return;
    }
    // What a correct checker should say for each policy.
    const shouldPass = {HeaderPolicy.strict, HeaderPolicy.firebaseRules};
    for (final policy in HeaderPolicy.values) {
      final host = await ctx.host(policy);
      try {
        await host.deployAtomic(b.outDir);
        final res = await Process.run(Platform.resolvedExecutable, [
          'run',
          'bin/flutter_web_cache_check.dart',
          'check',
          host.baseUri.toString(),
        ], workingDirectory: checker.path);
        final step = result.step('policy ${policy.name}');
        final expectedPass = shouldPass.contains(policy);
        final passed = res.exitCode == 0;
        step.check(
          expectedPass
              ? 'checker passes a correct deploy'
              : 'checker flags the misconfiguration',
          passed == expectedPass,
          'exit ${res.exitCode}; ${(res.stdout as String).trim().split('\n').where((l) => l.contains('[')).join(' | ')}',
        );
        step.notes.add(host.log.map((r) => '${r.path}:${r.status}').join(', '));
      } finally {
        await host.stop();
      }
    }
  }
}
