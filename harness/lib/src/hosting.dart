import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// How a hosting provider sets `Cache-Control` for a Flutter web build.
enum HeaderPolicy {
  /// No `Cache-Control` at all, but `Last-Modified`/`ETag` present, so the
  /// browser applies heuristic freshness (10% of the resource's age). This is
  /// what a bare nginx/Apache/`python -m http.server` deploy looks like.
  heuristic,

  /// Firebase Hosting with no `headers` rules: everything `max-age=3600`.
  firebaseDefaults,

  /// Firebase Hosting with the rules `flutter_web_cache_check fb-config`
  /// writes: hashed entrypoints immutable, bootloaders/manifests no-cache,
  /// everything else the Firebase default `max-age=3600`.
  firebaseRules,

  /// The fully correct policy for a content-hashed build: hashed files
  /// immutable, *every* unhashed file `no-cache`.
  strict,

  /// Misconfiguration: everything `max-age=31536000, immutable`.
  cacheEverything,

  /// Misconfiguration: `index.html` revalidates but `flutter_bootstrap.js`
  /// (and everything else) is cached for a year.
  bootstrapCached,

  /// Misconfiguration: `**/*.{js,wasm,mjs,png}` set to immutable with unguarded
  /// SPA rewrite (`**` -> `/index.html`).
  naiveImmutableGlobs,
}

final RegExp _hashedEntrypoint = RegExp(
  r'^main\.dart(_module\d+)?\.[a-f0-9]{8}\.(js|wasm|mjs)$',
);
final RegExp _hashedAsset = RegExp(r'\.[a-f0-9]{8}(\.[A-Za-z0-9]+)?$');
const Set<String> _unhashedAssetManifests = {
  'assets/AssetManifest.json',
  'assets/AssetManifest.bin',
  'assets/AssetManifest.bin.json',
  'assets/FontManifest.json',
  'assets/NOTICES',
};

const String _immutableDirective = 'public, max-age=31536000, immutable';
const String _revalidateDirective = 'max-age=0, must-revalidate';
const String _noCacheDirective = 'max-age=0, must-revalidate, no-cache';

/// `Cache-Control` for [relPath] under [policy]; null means omit the header.
String? cacheControlFor(HeaderPolicy policy, String relPath) {
  final base = p.posix.basename(relPath);
  final isHashedEntry = _hashedEntrypoint.hasMatch(base);
  final isHashedAsset =
      relPath.startsWith('assets/') && _hashedAsset.hasMatch(base);
  switch (policy) {
    case HeaderPolicy.heuristic:
      return null;
    case HeaderPolicy.firebaseDefaults:
      return 'max-age=3600';
    case HeaderPolicy.firebaseRules:
      return _firebaseRulesCacheControl(relPath, isHashedEntry: isHashedEntry);
    case HeaderPolicy.strict:
      return (isHashedEntry || isHashedAsset)
          ? _immutableDirective
          : _noCacheDirective;
    case HeaderPolicy.cacheEverything:
      return _immutableDirective;
    case HeaderPolicy.bootstrapCached:
      return base == 'index.html' ? _noCacheDirective : _immutableDirective;
    case HeaderPolicy.naiveImmutableGlobs:
      return _isNaiveImmutableAsset(relPath)
          ? _immutableDirective
          : 'max-age=3600';
  }
}

String _firebaseRulesCacheControl(
  String relPath, {
  required bool isHashedEntry,
}) {
  // 5-rule last-match-wins stack from `fb-config`:
  // 1. "**" -> "max-age=0, must-revalidate"
  var result = _revalidateDirective;
  // 2. "**/main.dart.*.{js,wasm,mjs}" -> "public, max-age=31536000, immutable"
  if (isHashedEntry) result = _immutableDirective;
  // 3. "assets/**" -> "public, max-age=31536000, immutable"
  if (relPath.startsWith('assets/')) result = _immutableDirective;
  // 4. "assets/@(AssetManifest.json|AssetManifest.bin|AssetManifest.bin.json|FontManifest.json|NOTICES)" -> "max-age=0, must-revalidate"
  if (_unhashedAssetManifests.contains(relPath)) result = _revalidateDirective;
  // 5. "404.html" -> "max-age=0, must-revalidate"
  if (relPath == '404.html') result = _revalidateDirective;
  return result;
}

bool _isNaiveImmutableAsset(String relPath) =>
    relPath.endsWith('.js') ||
    relPath.endsWith('.wasm') ||
    relPath.endsWith('.mjs') ||
    relPath.endsWith('.png');

/// One request the simulated host answered.
class ServedRequest {
  ServedRequest(
    this.path,
    this.status,
    this.cacheControl, {
    required this.conditional,
  });

  final String path;
  final int status;
  final String? cacheControl;
  final bool conditional;

  Map<String, Object?> toJson() => {
    'path': path,
    'status': status,
    'cacheControl': cacheControl,
    'conditional': conditional,
  };
}

/// A local stand-in for a static host / CDN with controllable headers,
/// deploy atomicity, and edge-cached `index.html`.
class HostingServer {
  HostingServer({
    required this.policy,
    this.cdnIndexTtl = Duration.zero,
    this.spaRewrite = false,
    this.spaRewriteAll = false,
    this.basePath = '/',
    this.negativeCacheTtl = Duration.zero,
  });

  HeaderPolicy policy;

  /// `Cache-Control` applied to 404 responses. Zero = `no-cache`
  /// (Firebase Hosting, S3). Some CDNs apply the path's header rules to 404s
  /// too, which caches a missing hashed file for a year.
  final Duration negativeCacheTtl;

  /// URL prefix the site is mounted under (matches `--base-href`).
  final String basePath;

  /// Emulates a CDN edge that keeps serving the previous `index.html` for this
  /// long after a deploy, regardless of origin headers.
  final Duration cdnIndexTtl;

  /// Rewrite unknown paths without dots to `index.html` (guarded SPA mode).
  final bool spaRewrite;

  /// Rewrite ALL unknown paths (including missing `.js`/`.png`) to `index.html`
  /// (`"source": "**", "destination": "/index.html"`).
  bool spaRewriteAll;

  late final Directory root = Directory.systemTemp.createTempSync(
    'redteam_host_',
  );
  Directory get liveDir => Directory(p.join(root.path, 'live'));

  HttpServer? _server;
  final List<ServedRequest> log = <ServedRequest>[];
  List<int>? _frozenIndex;
  DateTime? _frozenUntil;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server!.port}$basePath');

  Future<void> start() async {
    liveDir.createSync(recursive: true);
    _server = await shelf_io.serve(_handle, InternetAddress.loopbackIPv4, 0);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  }

  // --- deploy strategies -------------------------------------------------

  void _freezeIndexIfCdn() {
    if (cdnIndexTtl == Duration.zero) return;
    final index = File(p.join(liveDir.path, 'index.html'));
    if (index.existsSync()) {
      _frozenIndex = index.readAsBytesSync();
      _frozenUntil = DateTime.now().add(cdnIndexTtl);
    }
  }

  /// Replace the whole site in one step (old files gone). What Firebase
  /// Hosting and most "upload then flip" hosts do.
  Future<void> deployAtomic(Directory build) async {
    _freezeIndexIfCdn();
    final staging = Directory(p.join(root.path, 'staging'));
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    await _copyTree(build, staging);
    final old = Directory(p.join(root.path, 'old'));
    if (old.existsSync()) old.deleteSync(recursive: true);
    if (liveDir.existsSync()) liveDir.renameSync(old.path);
    staging.renameSync(liveDir.path);
    if (old.existsSync()) old.deleteSync(recursive: true);
  }

  /// Copy the new build over the existing site without deleting anything
  /// (rsync without `--delete`, `gsutil cp`, S3 sync): old hashed files stay.
  Future<void> deployOverlay(Directory build) async {
    _freezeIndexIfCdn();
    await _copyTree(build, liveDir);
  }

  /// Copy only the files [include] accepts (in the order the source lists
  /// them): simulates a deploy caught mid-way, or a host that uploads
  /// `index.html` before the files it references.
  Future<void> deployPartial(
    Directory build,
    bool Function(String relPath) include,
  ) async {
    _freezeIndexIfCdn();
    await _copyTree(build, liveDir, include: include);
  }

  /// Delete live files matching [predicate] (e.g. purge old hashed files).
  void deleteWhere(bool Function(String relPath) predicate) {
    for (final entity
        in liveDir.listSync(recursive: true).whereType<File>().toList()) {
      final rel = p.relative(entity.path, from: liveDir.path);
      if (predicate(rel)) entity.deleteSync();
    }
  }

  static Future<void> _copyTree(
    Directory from,
    Directory to, {
    bool Function(String relPath)? include,
  }) async {
    for (final entity in from.listSync(recursive: true)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: from.path);
      if (include != null && !include(rel)) continue;
      final dest = File(p.join(to.path, rel));
      dest.parent.createSync(recursive: true);
      entity.copySync(dest.path);
    }
  }

  /// Relative paths of everything currently live.
  List<String> liveFiles() =>
      liveDir
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => p.relative(f.path, from: liveDir.path))
          .toList()
        ..sort();

  // --- serving --------------------------------------------------------------

  Future<Response> _handle(Request request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      return Response(405);
    }
    final rawRel = Uri.decodeComponent(request.url.path);
    final strippedRel = _stripBasePath(rawRel);
    if (strippedRel == null) {
      log.add(ServedRequest(rawRel, 404, null, conditional: false));
      return Response.notFound('outside base path: $rawRel');
    }
    final originalRel = strippedRel;
    final resolved = _resolvePayload(originalRel);
    final rel = resolved.resolvedRel;
    final bytes = resolved.bytes;

    // Header matching uses the pre-rewrite request path (originalRel).
    final cacheControl = cacheControlFor(policy, originalRel);
    if (bytes == null) {
      final notFoundCc = _notFoundCacheControl(cacheControl);
      log.add(ServedRequest(originalRel, 404, notFoundCc, conditional: false));
      return Response.notFound(
        'not found: $originalRel',
        headers: {'cache-control': notFoundCc},
      );
    }

    final etag = '"${md5.convert(bytes)}"';
    final ifNoneMatch = request.headers['if-none-match'];
    final headers = <String, String>{
      'etag': etag,
      'last-modified': HttpDate.format(
        DateTime.now().toUtc().subtract(const Duration(days: 30)),
      ),
      'content-type': _contentType(rel),
      'cache-control': ?cacheControl,
    };
    if (ifNoneMatch != null && ifNoneMatch == etag) {
      log.add(ServedRequest(rel, 304, cacheControl, conditional: true));
      return Response(304, headers: headers);
    }
    log.add(
      ServedRequest(rel, 200, cacheControl, conditional: ifNoneMatch != null),
    );
    return Response.ok(
      request.method == 'HEAD' ? null : bytes,
      headers: headers,
    );
  }

  String? _stripBasePath(String rawRel) {
    var rel = rawRel;
    final prefix = basePath.substring(1);
    if (prefix.isNotEmpty) {
      if (!rel.startsWith(prefix)) return null;
      rel = rel.substring(prefix.length);
    }
    if (rel.isEmpty || rel.endsWith('/')) {
      rel = '${rel}index.html';
    }
    return rel;
  }

  ({String resolvedRel, List<int>? bytes}) _resolvePayload(String rel) {
    if (rel == 'index.html' &&
        _frozenIndex != null &&
        DateTime.now().isBefore(_frozenUntil!)) {
      return (resolvedRel: rel, bytes: _frozenIndex);
    }
    final file = File(p.join(liveDir.path, rel));
    if (file.existsSync()) {
      return (resolvedRel: rel, bytes: file.readAsBytesSync());
    }
    final shouldSpaFallback =
        spaRewriteAll ||
        policy == HeaderPolicy.naiveImmutableGlobs ||
        (spaRewrite && !rel.contains('.'));
    if (shouldSpaFallback) {
      final index = File(p.join(liveDir.path, 'index.html'));
      return (
        resolvedRel: 'index.html',
        bytes: index.existsSync() ? index.readAsBytesSync() : null,
      );
    }
    return (resolvedRel: rel, bytes: null);
  }

  String _notFoundCacheControl(String? pathCacheControl) {
    if (negativeCacheTtl != Duration.zero) {
      return 'max-age=${negativeCacheTtl.inSeconds}';
    }
    return switch (policy) {
      HeaderPolicy.firebaseRules => cacheControlFor(policy, '404.html')!,
      HeaderPolicy.firebaseDefaults => pathCacheControl ?? 'max-age=3600',
      _ => 'no-cache',
    };
  }

  static String _contentType(String rel) {
    switch (p.extension(rel)) {
      case '.html':
        return 'text/html; charset=utf-8';
      case '.js':
      case '.mjs':
        return 'text/javascript';
      case '.wasm':
        return 'application/wasm';
      case '.json':
        return 'application/json';
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.svg':
        return 'image/svg+xml';
      case '.ttf':
        return 'font/ttf';
      case '.otf':
        return 'font/otf';
      case '.txt':
      case '.frag':
        return 'text/plain; charset=utf-8';
      default:
        return 'application/octet-stream';
    }
  }

  Map<String, Object?> snapshot() => {
    'policy': policy.name,
    'cdnIndexTtlSeconds': cdnIndexTtl.inSeconds,
    'served': log.map((r) => r.toJson()).toList(),
  };

  String describe() => json.encode(snapshot());
}
