// Red-team fixture app.
//
// On startup it loads one of every asset type through every API path that
// exists (manifest-resolved, raw key, raw URL) and publishes a JSON report to
// `window.__redteamJson`. The harness reads that over CDP. `window.__redteamLoadLazy`
// loads a second set on demand, so the harness can deploy a new version
// underneath an already-open tab and see what the old code gets.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:sample_pkg/sample_pkg.dart';
import 'package:vector_graphics/vector_graphics.dart';

const String appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

@JS('__redteamJson')
external set _redteamJson(JSString value);

@JS('__redteamLoadLazy')
external set _redteamLoadLazy(JSFunction value);

final Map<String, Object?> _report = <String, Object?>{
  'version': appVersion,
  'done': false,
  'lazyDone': false,
  'assets': <String, Object?>{},
  'lazyAssets': <String, Object?>{},
  'manifest': <String, Object?>{},
};

void _publish() {
  _redteamJson = jsonEncode(_report).toJS;
}

void main() {
  _publish();
  _redteamLoadLazy = (() {
    unawaited(_loadLazy());
  }).toJS;
  runApp(const RedTeamApp());
  unawaited(_loadEager());
}

/// Records one probe result. [detail] should make "what did we actually get"
/// obvious in the report: resolved key, byte count, HTTP status, content.
Future<void> _probe(
  Map<String, Object?> into,
  String name,
  Future<String> Function() body,
) async {
  final sw = Stopwatch()..start();
  try {
    final detail = await body().timeout(const Duration(seconds: 15));
    into[name] = <String, Object?>{
      'ok': true,
      'detail': detail,
      'ms': sw.elapsedMilliseconds,
    };
  } catch (e) {
    into[name] = <String, Object?>{
      'ok': false,
      'detail': '$e',
      'ms': sw.elapsedMilliseconds,
    };
  }
  _publish();
}

Future<String> _rawBytes(String key) async {
  final ByteData data = await rootBundle.load(key);
  return '${data.lengthInBytes} bytes';
}

Future<String> _rawString(String key) async {
  final String s = await rootBundle.loadString(key, cache: false);
  return s.trim();
}

/// Resolves an [AssetImage] the way `Image.asset` does (via AssetManifest,
/// devicePixelRatio 2.0 so the 2.0x variant is preferred) and decodes it.
Future<String> _image(AssetImage provider) async {
  const config = ImageConfiguration(devicePixelRatio: 2.0);
  final AssetBundleImageKey key = await provider.obtainKey(config);
  final completer = Completer<String>();
  final ImageStream stream = provider.resolve(config);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool sync) {
      if (!completer.isCompleted) {
        completer.complete(
          '${key.name} ${info.image.width}x${info.image.height} scale=${key.scale}',
        );
      }
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? st) {
      if (!completer.isCompleted) {
        completer.completeError('resolved ${key.name}: $error');
      }
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// Fetches the URL the engine's asset manager would use for a raw key. This
/// is what plugins (video_player_web, etc.) do; it bypasses the manifest.
Future<String> _assetUrl(String key) async {
  final String url = ui_web.assetManager.getAssetUrl(key);
  final http.Response resp = await http.get(Uri.parse(url));
  if (resp.statusCode != 200) {
    throw Exception('GET $url → ${resp.statusCode}');
  }
  return '$url → ${resp.statusCode} (${resp.bodyBytes.length} bytes)';
}

Future<void> _loadEager() async {
  final assets = _report['assets']! as Map<String, Object?>;

  // Manifest-resolved images, one per codec, plus resolution variants.
  await _probe(
    assets,
    'image.png(2.0x)',
    () => _image(const AssetImage('assets/images/logo.png')),
  );
  await _probe(
    assets,
    'image.jpg',
    () => _image(const AssetImage('assets/images/photo.jpg')),
  );
  await _probe(
    assets,
    'image.gif',
    () => _image(const AssetImage('assets/images/anim.gif')),
  );
  await _probe(
    assets,
    'image.webp',
    () => _image(const AssetImage('assets/images/pic.webp')),
  );
  await _probe(
    assets,
    'image.bmp',
    () => _image(const AssetImage('assets/images/bitmap.bmp')),
  );
  await _probe(
    assets,
    'image.package',
    () => _image(const AssetImage(pkgImageAsset, package: pkgName)),
  );

  // Raw keys through rootBundle (the documented gap: no manifest consulted).
  await _probe(assets, 'raw.json', () => _rawString('assets/data/config.json'));
  await _probe(assets, 'raw.txt', () => _rawString('assets/data/notes.txt'));
  await _probe(assets, 'raw.bin', () => _rawBytes('assets/data/blob.bin'));
  await _probe(assets, 'raw.dir', () => _rawString('assets/dir/a.txt'));
  await _probe(assets, 'raw.package', () => _rawString(pkgTextKey));
  await _probe(assets, 'raw.png', () => _rawBytes('assets/images/logo.png'));
  await _probe(
    assets,
    'raw.font',
    () => _rawBytes('assets/fonts/AdwaitaMono-Bold.ttf'),
  );
  await _probe(
    assets,
    'raw.deployStamp',
    () => _rawString('assets/data/deploy.txt'),
  );

  // Transformed asset: bytes must be vector_graphics binary, not SVG text.
  await _probe(assets, 'transformed.svg', () async {
    final ByteData data = await rootBundle.load('assets/svg/icon.svg');
    final Uint8List bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final bool looksLikeSvg =
        bytes.length > 4 && String.fromCharCodes(bytes.take(4)) == '<svg';
    if (looksLikeSvg) {
      throw Exception('got raw SVG text; transformer did not run');
    }
    // Also decode it through the real widget loader.
    await const AssetBytesLoader('assets/svg/icon.svg').loadBytes(null);
    return '${bytes.length} bytes, compiled';
  });

  // Shader: FragmentProgram.fromAsset uses the raw key on the engine channel.
  await _probe(assets, 'shader.frag', () async {
    final ui.FragmentProgram program = await ui.FragmentProgram.fromAsset(
      'shaders/simple.frag',
    );
    program.fragmentShader();
    return 'compiled';
  });

  // Font manifest: what path does the engine load the custom font from?
  await _probe(assets, 'manifest.FontManifest', () async {
    final String s = await rootBundle.loadString(
      'FontManifest.json',
      cache: false,
    );
    final List<Object?> fonts = jsonDecode(s) as List<Object?>;
    final Map<String, Object?> adwaita = fonts
        .cast<Map<String, Object?>>()
        .firstWhere((f) => f['family'] == 'AdwaitaMono');
    final List<Object?> files = adwaita['fonts']! as List<Object?>;
    return (files.first! as Map<String, Object?>)['asset']! as String;
  });

  // Asset manifest: total keys and the variants recorded for logo.png.
  await _probe(assets, 'manifest.AssetManifest', () async {
    final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(
      rootBundle,
    );
    final List<AssetMetadata>? variants = manifest.getAssetVariants(
      'assets/images/logo.png',
    );
    (_report['manifest']! as Map<String, Object?>)['keys'] = manifest
        .listAssets()
        .length;
    return 'keys=${manifest.listAssets().length} logoVariants=${variants?.map((v) => '${v.key}@${v.targetDevicePixelRatio}').join(',')}';
  });

  // Raw URLs via the engine asset manager (what plugins do).
  await _probe(assets, 'url.json', () => _assetUrl('assets/data/config.json'));
  await _probe(assets, 'url.png', () => _assetUrl('assets/images/logo.png'));
  await _probe(assets, 'url.package', () => _assetUrl(pkgTextKey));

  _report['done'] = true;
  _publish();
}

Future<void> _loadLazy() async {
  final lazy = _report['lazyAssets']! as Map<String, Object?>;
  await _probe(
    lazy,
    'lazy.image.png',
    () => _image(const AssetImage('assets/lazy/lazy.png')),
  );
  await _probe(lazy, 'lazy.raw.txt', () => _rawString('assets/lazy/lazy.txt'));
  await _probe(
    lazy,
    'lazy.deployStamp',
    () => _rawString('assets/lazy/deploy.txt'),
  );
  await _probe(lazy, 'lazy.url.txt', () => _assetUrl('assets/lazy/lazy.txt'));
  _report['lazyDone'] = true;
  _publish();
}

class RedTeamApp extends StatelessWidget {
  const RedTeamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'redteam $appVersion',
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'version $appVersion',
                style: const TextStyle(
                  fontFamily: 'AdwaitaMono',
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Image.asset('assets/images/logo.png', width: 32, height: 32),
              const SizedBox(
                width: 24,
                height: 24,
                child: VectorGraphic(
                  loader: AssetBytesLoader('assets/svg/icon.svg'),
                ),
              ),
              const Icon(Icons.check_circle),
            ],
          ),
        ),
      ),
    );
  }
}
