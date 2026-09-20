import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:redteam_harness/redteam_harness.dart';
import 'package:test/test.dart';

void main() {
  group('Phase 4 (TDD): Companion Simulator Alignment (hosting.dart)', () {
    test('HeaderPolicy.firebaseRules serves max-age=0, must-revalidate on roots and immutable on hashed assets/**', () async {
      final HostingServer host = HostingServer(
        policy: HeaderPolicy.firebaseRules,
      );
      await host.start();
      try {
        for (final String rel in <String>[
          'index.html',
          'assets/AssetManifest.bin.json',
          'assets/AssetManifest.bin.10579154.json',
          'assets/packages/foo/bar.a1b2c3d4.png',
          '404.html',
        ]) {
          final File file = File.fromUri(host.liveDir.uri.resolve(rel));
          file.parent.createSync(recursive: true);
          file.writeAsStringSync('content:$rel');
        }

        final http.Response indexResp = await http.get(
          host.baseUri.resolve('index.html'),
        );
        expect(indexResp.statusCode, 200);
        expect(
          indexResp.headers['cache-control'],
          'max-age=0, must-revalidate',
        );

        final http.Response unhashedManifestResp = await http.get(
          host.baseUri.resolve('assets/AssetManifest.bin.json'),
        );
        expect(unhashedManifestResp.statusCode, 200);
        expect(
          unhashedManifestResp.headers['cache-control'],
          'max-age=0, must-revalidate',
        );

        final http.Response hashedManifestResp = await http.get(
          host.baseUri.resolve('assets/AssetManifest.bin.10579154.json'),
        );
        expect(hashedManifestResp.statusCode, 200);
        expect(
          hashedManifestResp.headers['cache-control'],
          'public, max-age=31536000, immutable',
        );

        final http.Response hashedAssetResp = await http.get(
          host.baseUri.resolve('assets/packages/foo/bar.a1b2c3d4.png'),
        );
        expect(hashedAssetResp.statusCode, 200);
        expect(
          hashedAssetResp.headers['cache-control'],
          'public, max-age=31536000, immutable',
        );

        final http.Response notFoundPageResp = await http.get(
          host.baseUri.resolve('404.html'),
        );
        expect(notFoundPageResp.statusCode, 200);
        expect(
          notFoundPageResp.headers['cache-control'],
          'max-age=0, must-revalidate',
        );
      } finally {
        await host.stop();
      }
    });

    test('pre-rewrite path matching: unguarded SPA rewrite applies original request path headers to 200 index.html fallback (P4/F-05)', () async {
      final HostingServer host = HostingServer(
        policy: HeaderPolicy.naiveImmutableGlobs,
        spaRewriteAll: true,
      );
      await host.start();
      try {
        final File indexFile = File.fromUri(
          host.liveDir.uri.resolve('index.html'),
        );
        indexFile.parent.createSync(recursive: true);
        indexFile.writeAsStringSync('<!DOCTYPE html><html></html>');

        final http.Response poisonedResp = await http.get(
          host.baseUri.resolve('main.dart.deadbeef.js'),
        );
        expect(poisonedResp.statusCode, 200);
        expect(poisonedResp.headers['content-type'], contains('text/html'));
        expect(
          poisonedResp.headers['cache-control'],
          'public, max-age=31536000, immutable',
        );

        // Switch to guarded HeaderPolicy.firebaseRules
        host
          ..policy = HeaderPolicy.firebaseRules
          ..spaRewriteAll = false;
        final http.Response guardedResp = await http.get(
          host.baseUri.resolve('main.dart.deadbeef.js'),
        );
        expect(guardedResp.statusCode, 404);
        expect(
          guardedResp.headers['cache-control'],
          'max-age=0, must-revalidate',
        );
      } finally {
        await host.stop();
      }
    });

    test('HeaderPolicy.naiveImmutableGlobs enables unguarded SPA rewrite by default and HeaderPolicy.firebaseDefaults inherits max-age=3600 on 404 (F-05 & F-06)', () async {
      final HostingServer host = HostingServer(
        policy: HeaderPolicy.naiveImmutableGlobs,
      );
      await host.start();
      try {
        final File indexFile = File.fromUri(
          host.liveDir.uri.resolve('index.html'),
        );
        indexFile.parent.createSync(recursive: true);
        indexFile.writeAsStringSync('<!DOCTYPE html><html></html>');

        final http.Response naiveResp = await http.get(
          host.baseUri.resolve('main.dart.00000000.js'),
        );
        expect(naiveResp.statusCode, 200);
        expect(naiveResp.headers['content-type'], contains('text/html'));
        expect(
          naiveResp.headers['cache-control'],
          'public, max-age=31536000, immutable',
        );

        host.policy = HeaderPolicy.firebaseDefaults;
        final http.Response default404Resp = await http.get(
          host.baseUri.resolve('main.dart.00000000.js'),
        );
        expect(default404Resp.statusCode, 404);
        expect(default404Resp.headers['cache-control'], 'max-age=3600');
      } finally {
        await host.stop();
      }
    });
  });
}
