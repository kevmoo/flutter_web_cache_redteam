import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'legacy_sw.dart';

/// A Flutter SDK checkout to build with.
class FlutterSdk {
  FlutterSdk(this.label, this.root);

  final String label;
  final Directory root;

  String get flutterBin => p.join(root.path, 'bin', 'flutter');

  static String _home() => Platform.environment['HOME'] ?? '';

  /// `master` = what ships today (Phase 1 only).
  static FlutterSdk master() => FlutterSdk(
    'master',
    Directory(
      Platform.environment['REDTEAM_FLUTTER_MASTER'] ??
          p.join(_home(), 'github', 'flutter'),
    ),
  );

  /// The `web-content-hash-phase-3` branch (Phases 1–3).
  static FlutterSdk phase3() => FlutterSdk(
    'phase3',
    Directory(
      Platform.environment['REDTEAM_FLUTTER_PHASE3'] ??
          p.join(_home(), 'github', '_flutter-web-content-hash-phase-3'),
    ),
  );

  static FlutterSdk byLabel(String label) => switch (label) {
    'master' => master(),
    'phase3' => phase3(),
    _ => throw ArgumentError.value(label, 'label', 'expected master|phase3'),
  };

  Future<String> version() async {
    final res = await Process.run(flutterBin, ['--version', '--machine']);
    if (res.exitCode != 0) return 'unknown';
    final out = res.stdout as String;
    final start = out.indexOf('{');
    if (start < 0) return 'unknown';
    final map = json.decode(out.substring(start)) as Map<String, Object?>;
    return '${map['frameworkVersion']} @ ${(map['frameworkRevision'] as String?)?.substring(0, 10)}';
  }
}

/// Everything that distinguishes one build of the sample app from another.
class BuildOptions {
  const BuildOptions({
    required this.version,
    this.contentHash = true,
    this.wasm = false,
    this.baseHref,
    this.pwaStrategy = 'offline-first',
    this.flavor,
    this.legacyServiceWorker = false,
    this.customIndexHtml,
    this.customBootstrapJs,
    this.target,
    this.extraArgs = const <String>[],
  });

  /// Shown by the app and reported via `window.__redteam.version`.
  final String version;
  final bool contentHash;
  final bool wasm;
  final String? baseHref;
  final String pwaStrategy;
  final String? flavor;

  /// Replace the generated service worker with the pre-#176834 offline-first
  /// worker (what every app deployed before Flutter 3.38 installed in users'
  /// browsers).
  final bool legacyServiceWorker;

  /// Contents to write to `web/index.html` before building (null = default).
  final String? customIndexHtml;

  /// Contents to write to `web/flutter_bootstrap.js` before building.
  final String? customBootstrapJs;

  /// Entrypoint passed as `--target` (default `lib/main.dart`).
  final String? target;
  final List<String> extraArgs;

  String get key => [
    version,
    if (contentHash) 'hash' else 'nohash',
    if (wasm) 'wasm',
    // No '=' anywhere: dart2js splits `--packages=<path>` on it.
    if (baseHref != null) 'base-$baseHref',
    'pwa-$pwaStrategy',
    if (flavor != null) 'flavor-$flavor',
    if (legacyServiceWorker) 'legacysw',
    if (customIndexHtml != null)
      'customindex-${sha256.convert(utf8.encode(customIndexHtml!)).toString().substring(0, 6)}',
    if (customBootstrapJs != null)
      'custombootstrap-${sha256.convert(utf8.encode(customBootstrapJs!)).toString().substring(0, 6)}',
    if (target != null) 'target-${target!.split('/').last.split('.').first}',
    ...extraArgs,
  ].join('_').replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-');
}

class BuildResult {
  BuildResult({
    required this.sdk,
    required this.options,
    required this.srcDir,
    required this.outDir,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
  });

  final FlutterSdk sdk;
  final BuildOptions options;
  final Directory srcDir;
  final Directory outDir;
  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;

  bool get succeeded => exitCode == 0;

  /// Relative POSIX paths → sha256 of every file in the build output.
  Map<String, String> fileHashes() {
    final out = <String, String>{};
    for (final f in outDir.listSync(recursive: true).whereType<File>()) {
      final rel = p.posix.joinAll(
        p.split(p.relative(f.path, from: outDir.path)),
      );
      out[rel] = sha256.convert(f.readAsBytesSync()).toString();
    }
    return out;
  }

  /// The compiled JS/Wasm entrypoint basenames (hashed or not).
  List<String> entrypoints() =>
      outDir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where(
            (n) =>
                RegExp(r'^main\.dart(\.[a-f0-9]{8})?\.(js|wasm|mjs)$')
                    .hasMatch(n),
          )
          .toList()
        ..sort();

  Map<String, Object?> toJson() => {
    'sdk': sdk.label,
    'options': options.key,
    'exitCode': exitCode,
    'durationMs': duration.inMilliseconds,
    'entrypoints': succeeded ? entrypoints() : null,
    'stderrTail': stderr
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList()
        .reversed
        .take(5)
        .toList()
        .reversed
        .toList(),
  };
}

/// Builds `sample_app` with a given SDK and options into a per-key output
/// directory. Builds are cached by `(sdk, options.key)` for the run.
class Builder {
  Builder({required this.sampleAppDir, required this.workDir});

  final Directory sampleAppDir;
  final Directory workDir;
  final Map<String, BuildResult> _cache = <String, BuildResult>{};

  /// [incrementalFrom] reuses that build's source directory (and its
  /// `build/` + `.dart_tool/` state) instead of a fresh copy, i.e. what a
  /// developer's repeated `flutter build web` does.
  Future<BuildResult> build(
    FlutterSdk sdk,
    BuildOptions options, {
    BuildResult? incrementalFrom,
  }) async {
    final key =
        '${sdk.label}__${options.key}${incrementalFrom == null ? '' : '__incr'}';
    final cached = _cache[key];
    if (cached != null) return cached;

    final srcDir =
        incrementalFrom?.srcDir ?? Directory(p.join(workDir.path, 'src', key));
    final outDir =
        incrementalFrom?.outDir ?? Directory(p.join(workDir.path, 'out', key));
    if (incrementalFrom == null) {
      if (srcDir.existsSync()) srcDir.deleteSync(recursive: true);
      if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      _copyApp(sampleAppDir, srcDir);
    }
    // Stamp assets with the version so old code can detect new assets, and
    // swap in the per-version logo so an *image* (and its hash) changes too.
    for (final rel in ['assets/data/deploy.txt', 'assets/lazy/deploy.txt']) {
      File(p.join(srcDir.path, rel)).writeAsStringSync('${options.version}\n');
    }
    var variant = Directory(p.join(srcDir.path, 'variants', options.version));
    if (!variant.existsSync()) {
      variant = Directory(p.join(srcDir.path, 'variants', 'v1'));
    }
    for (final rel in ['logo.png', '2.0x/logo.png', '3.0x/logo.png']) {
      File(p.join(variant.path, rel))
          .copySync(p.join(srcDir.path, 'assets', 'images', rel));
    }

    if (options.customIndexHtml != null) {
      File(p.join(srcDir.path, 'web', 'index.html'))
          .writeAsStringSync(options.customIndexHtml!);
    }
    if (options.customBootstrapJs != null) {
      File(p.join(srcDir.path, 'web', 'flutter_bootstrap.js'))
          .writeAsStringSync(options.customBootstrapJs!);
    }

    final args = <String>[
      'build',
      'web',
      '--no-version-check',
      // Deprecated flag; only pass it when asking for something non-default.
      if (options.pwaStrategy != 'offline-first')
        '--pwa-strategy=${options.pwaStrategy}',
      '--dart-define=APP_VERSION=${options.version}',
      '-o',
      outDir.path,
      if (options.contentHash) '--web-content-hash',
      if (options.wasm) '--wasm',
      if (options.baseHref != null) '--base-href=${options.baseHref}',
      if (options.flavor != null) '--flavor=${options.flavor}',
      if (options.target != null) '--target=${options.target}',
      ...options.extraArgs,
    ];
    final started = DateTime.now();
    final res = await Process.run(
      sdk.flutterBin,
      args,
      workingDirectory: srcDir.path,
      environment: {'FLUTTER_SUPPRESS_ANALYTICS': 'true'},
    );
    final duration = DateTime.now().difference(started);

    if (res.exitCode == 0 && options.legacyServiceWorker) {
      injectLegacyServiceWorker(outDir);
    }

    final result = BuildResult(
      sdk: sdk,
      options: options,
      srcDir: srcDir,
      outDir: outDir,
      exitCode: res.exitCode,
      stdout: res.stdout as String,
      stderr: res.stderr as String,
      duration: duration,
    );
    _cache[key] = result;
    return result;
  }

  /// Copies `sample_app` and its sibling `sample_pkg` (path dependency) so
  /// the copy resolves without touching the checked-in tree.
  static void _copyApp(Directory from, Directory to) {
    _copyDir(from, to);
    _copyDir(
      Directory(p.join(from.parent.path, 'sample_pkg')),
      Directory(p.join(to.parent.path, 'sample_pkg')),
    );
  }

  static void _copyDir(Directory from, Directory to) {
    for (final entity in from.listSync(recursive: true)) {
      final rel = p.relative(entity.path, from: from.path);
      final top = p.split(rel).first;
      if (top == 'build' || top == '.dart_tool' || top == '.idea') continue;
      if (entity is File) {
        final dest = File(p.join(to.path, rel));
        dest.parent.createSync(recursive: true);
        entity.copySync(dest.path);
      }
    }
  }
}
