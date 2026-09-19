import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:redteam_harness/redteam_harness.dart';
import 'package:test/test.dart';

void main() {
  group('cacheControlFor', () {
    test('strict: hashed files immutable, everything else no-cache', () {
      expect(
        cacheControlFor(HeaderPolicy.strict, 'main.dart.ff283653.js'),
        contains('immutable'),
      );
      expect(
        cacheControlFor(HeaderPolicy.strict, 'main.dart.ff283653.wasm'),
        contains('immutable'),
      );
      expect(
        cacheControlFor(
          HeaderPolicy.strict,
          'assets/assets/images/logo.342887cc.png',
        ),
        contains('immutable'),
      );
      expect(
        cacheControlFor(HeaderPolicy.strict, 'flutter_bootstrap.js'),
        contains('no-cache'),
      );
      expect(
        cacheControlFor(HeaderPolicy.strict, 'assets/AssetManifest.bin.json'),
        contains('no-cache'),
      );
      expect(
        cacheControlFor(HeaderPolicy.strict, 'assets/assets/data/config.json'),
        contains('no-cache'),
      );
    });

    test('firebaseRules mirrors fb-config 5-rule stack: roots/manifests revalidate, assets/** immutable', () {
      expect(
        cacheControlFor(HeaderPolicy.firebaseRules, 'main.dart.ff283653.js'),
        contains('immutable'),
      );
      expect(
        cacheControlFor(HeaderPolicy.firebaseRules, 'flutter_bootstrap.js'),
        'max-age=0, must-revalidate',
      );
      expect(
        cacheControlFor(
          HeaderPolicy.firebaseRules,
          'assets/AssetManifest.bin.json',
        ),
        'max-age=0, must-revalidate',
      );
      expect(
        cacheControlFor(
          HeaderPolicy.firebaseRules,
          'assets/packages/foo/bar.a1b2c3d4.png',
        ),
        contains('immutable'),
      );
    });

    test('heuristic sends no header at all', () {
      expect(cacheControlFor(HeaderPolicy.heuristic, 'index.html'), isNull);
    });

    test('bootstrapCached only revalidates index.html', () {
      expect(
        cacheControlFor(HeaderPolicy.bootstrapCached, 'index.html'),
        contains('no-cache'),
      );
      expect(
        cacheControlFor(HeaderPolicy.bootstrapCached, 'flutter_bootstrap.js'),
        contains('immutable'),
      );
    });
  });

  group('HostingServer', () {
    test(
      'serves, revalidates with 304, and never caches 404s by default',
      () async {
        final host = HostingServer(policy: HeaderPolicy.strict);
        await host.start();
        try {
          host.liveDir.createSync(recursive: true);
          File.fromUri(host.liveDir.uri.resolve('index.html'))
              .writeAsStringSync('<html>v1</html>');
          final first = await http.get(host.baseUri.resolve('index.html'));
          expect(first.statusCode, 200);
          expect(first.headers['cache-control'], contains('no-cache'));
          final etag = first.headers['etag']!;
          final again = await http.get(
            host.baseUri.resolve('index.html'),
            headers: {'if-none-match': etag},
          );
          expect(again.statusCode, 304);
          final missing = await http.get(host.baseUri.resolve('nope.js'));
          expect(missing.statusCode, 404);
          expect(missing.headers['cache-control'], 'no-cache');
          expect(host.log.map((r) => r.status), [200, 304, 404]);
        } finally {
          await host.stop();
        }
      },
    );
  });
}
