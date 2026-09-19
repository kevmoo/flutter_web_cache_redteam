import 'package:path/path.dart' as p;

import 'builder.dart';
import 'hosting.dart';
import 'scenario.dart';
import 'scenarios_variants.dart';

const _v1 = BuildOptions(version: 'v1');
const _v2 = BuildOptions(version: 'v2');

/// All scenarios, in the order they should run.
List<Scenario> allScenarios() => <Scenario>[
  for (final policy in HeaderPolicy.values) WarmUpgradeScenario(policy),
  NonAtomicDeployScenario(HeaderPolicy.strict),
  NonAtomicDeployScenario(HeaderPolicy.firebaseDefaults),
  NonAtomicDeployScenario(
    HeaderPolicy.strict,
    negativeCacheTtl: const Duration(minutes: 5),
  ),
  DeployUnderOpenTabScenario(),
  RollbackScenario(HeaderPolicy.strict),
  RollbackScenario(HeaderPolicy.firebaseDefaults),
  LegacyServiceWorkerMigrationScenario(),
  LegacyServiceWorkerMigrationScenario(HeaderPolicy.firebaseDefaults),
  CdnStaleIndexScenario(),
  ...variantScenarios(),
];

/// S1: returning user, v1 cached, v2 deployed atomically. Does the next visit
/// get v2, under each hosting header policy?
class WarmUpgradeScenario extends Scenario {
  WarmUpgradeScenario(this.policy);

  final HeaderPolicy policy;

  @override
  String get id => 'S1.${policy.name}';
  @override
  String get title => 'warm-cache upgrade under ${policy.name} headers';
  @override
  String get description =>
      'First visit on v1, atomic deploy of v2, then two more visits with the same browser profile.';

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final v1 = await ctx.build(_v1);
    final v2 = await ctx.build(_v2);
    result.builds.addAll([v1.toJson(), v2.toJson()]);
    if (!v1.succeeded || !v2.succeeded) {
      result.error = 'build failed: ${v1.stderr}\n${v2.stderr}';
      return;
    }

    final host = await ctx.host(policy);
    final profile = ctx.freshProfile(id);
    try {
      await host.deployAtomic(v1.outDir);
      var chrome = await ctx.chrome(profile);
      var step = result.step('first visit (v1)');
      var report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v1');
      step.notes.add(requestSources(chrome));
      await chrome.close();

      await host.deployAtomic(v2.outDir);
      chrome = await ctx.chrome(profile);
      step = result.step('second visit after v2 deploy');
      report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v2');
      step.notes.add(requestSources(chrome));
      _checkDeployStamp(step, report, 'v2');

      step = result.step('third visit');
      report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v2');
      step.notes.add(requestSources(chrome));
      _checkDeployStamp(step, report, 'v2');
      await chrome.close();
    } finally {
      await host.stop();
    }
  }
}

/// The asset `assets/data/deploy.txt` carries the version it was built with;
/// a mismatch with the running code means the user is on a mixed deploy.
void _checkDeployStamp(
  Step step,
  Map<String, Object?>? report,
  String expected,
) {
  final assets = report?['assets'] as Map<String, Object?>?;
  final raw = assets?['raw.deployStamp'] as Map<String, Object?>?;
  final resolved = assets?['resolved.deployStamp'] as Map<String, Object?>?;
  // Prefer the manifest-resolved read (survives hashed assets); fall back to
  // the raw key so master-only reports still work.
  final Map<String, Object?>? source = resolved?['ok'] == true ? resolved : raw;
  final stamp = source?['detail'];
  step.check(
    'asset deploy stamp is $expected',
    stamp == expected,
    'stamp=$stamp code=${report?['version']}',
  );
}

/// S2: the host uploads the shell (index/bootstrap) before the new hashed
/// entrypoint exists, or a deploy is caught half-way.
class NonAtomicDeployScenario extends Scenario {
  NonAtomicDeployScenario(this.policy, {this.negativeCacheTtl = Duration.zero});

  final HeaderPolicy policy;

  /// Model a CDN that caches 404s (see [HostingServer.negativeCacheTtl]).
  final Duration negativeCacheTtl;

  @override
  String get id =>
      'S2.${policy.name}${negativeCacheTtl == Duration.zero ? '' : '.negcache'}';
  @override
  String get title =>
      'non-atomic deploy (shell before entrypoint) under ${policy.name}';
  @override
  String get description =>
      'v1 live and cached; v2 index.html/flutter_bootstrap.js copied first; a user loads in that window; then the rest lands.';

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final v1 = await ctx.build(_v1);
    final v2 = await ctx.build(_v2);
    result.builds.addAll([v1.toJson(), v2.toJson()]);
    if (!v1.succeeded || !v2.succeeded) {
      result.error = 'build failed';
      return;
    }
    final host = await ctx.host(policy, negativeCacheTtl: negativeCacheTtl);
    final profile = ctx.freshProfile(id);
    try {
      await host.deployAtomic(v1.outDir);
      final chrome = await ctx.chrome(profile);
      var step = result.step('warm up on v1');
      var report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v1');

      const shell = {
        'index.html',
        'flutter_bootstrap.js',
        'flutter.js',
        'version.json',
      };
      await host.deployPartial(v2.outDir, (rel) => shell.contains(rel));
      step = result.step(
        'load during the window: v2 shell, v1 entrypoint/assets',
      );
      report = await loadAndCapture(
        step,
        chrome,
        host,
        host.baseUri,
        timeout: const Duration(seconds: 15),
      );
      step.check(
        'app booted during window',
        report != null,
        report == null
            ? 'blank: entrypoint 404'
            : 'version ${report['version']}',
      );
      step.check(
        'no failed requests',
        chrome.requests.every(
          (r) => r.failure == null && (r.status ?? 0) < 400,
        ),
        failedRequestsSummary(chrome),
      );
      step.notes.add(requestSources(chrome));

      await host.deployOverlay(v2.outDir);
      step = result.step(
        'load after deploy completes (old files still present)',
      );
      report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v2');
      _checkDeployStamp(step, report, 'v2');
      step.notes.add(requestSources(chrome));
      await chrome.close();
    } finally {
      await host.stop();
    }
  }
}

/// S3: a tab is open on v1, v2 deploys (v1's hashed files disappear), the
/// user navigates within the app and it fetches assets it hadn't loaded yet.
class DeployUnderOpenTabScenario extends Scenario {
  @override
  String get id => 'S3';
  @override
  String get title => 'deploy underneath an open tab, then lazy asset loads';
  @override
  String get description =>
      'Old code asks for assets after the deploy: does it get old bytes, new bytes (mixed versions), or 404s?';

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final v1 = await ctx.build(_v1);
    final v2 = await ctx.build(_v2);
    result.builds.addAll([v1.toJson(), v2.toJson()]);
    if (!v1.succeeded || !v2.succeeded) {
      result.error = 'build failed';
      return;
    }
    final host = await ctx.host(HeaderPolicy.strict);
    final profile = ctx.freshProfile(id);
    try {
      await host.deployAtomic(v1.outDir);
      final chrome = await ctx.chrome(profile);
      var step = result.step('open tab on v1');
      var report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v1');

      await host.deployAtomic(v2.outDir);
      step = result.step('v2 deployed; old tab loads lazy assets');
      chrome.resetObservations();
      host.log.clear();
      report = await chrome.triggerLazyLoad();
      step.capture(chrome, host, report);
      step.check('lazy load completed', report != null);
      final lazy = (report?['lazyAssets'] as Map<String, Object?>?) ?? const {};
      final failed = lazy.entries
          .where((e) => (e.value as Map<String, Object?>)['ok'] != true)
          .map(
            (e) => '${e.key}: ${(e.value as Map<String, Object?>)['detail']}',
          )
          .toList();
      step.check(
        'lazy assets loaded (no 404)',
        failed.isEmpty,
        failed.join(' | '),
      );
      final stampProbe =
          (lazy['lazy.resolved.deployStamp'] as Map<String, Object?>?)?['ok'] ==
              true
          ? lazy['lazy.resolved.deployStamp']
          : lazy['lazy.deployStamp'];
      final stamp = (stampProbe as Map<String, Object?>?)?['detail'];
      step.check(
        'lazy asset bytes belong to the running version (v1)',
        stamp == 'v1',
        'old code got assets stamped "$stamp"',
      );
      step.notes.add(requestSources(chrome));

      step = result.step('reload the tab');
      report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v2');
      await chrome.close();
    } finally {
      await host.stop();
    }
  }
}

/// S4: v2 is live and cached, then the operator rolls back to v1.
class RollbackScenario extends Scenario {
  RollbackScenario(this.policy);

  final HeaderPolicy policy;

  @override
  String get id => 'S4.${policy.name}';
  @override
  String get title => 'rollback v2 → v1 under ${policy.name}';
  @override
  String get description =>
      'Same hashes come back; does the browser serve the v2 shell it cached?';

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final v1 = await ctx.build(_v1);
    final v2 = await ctx.build(_v2);
    result.builds.addAll([v1.toJson(), v2.toJson()]);
    if (!v1.succeeded || !v2.succeeded) {
      result.error = 'build failed';
      return;
    }
    final host = await ctx.host(policy);
    final profile = ctx.freshProfile(id);
    try {
      await host.deployAtomic(v1.outDir);
      var chrome = await ctx.chrome(profile);
      var step = result.step('visit v1');
      var report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v1');
      await chrome.close();

      await host.deployAtomic(v2.outDir);
      chrome = await ctx.chrome(profile);
      step = result.step('visit v2');
      report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v2');
      await chrome.close();

      await host.deployAtomic(v1.outDir);
      chrome = await ctx.chrome(profile);
      step = result.step('visit after rollback to v1');
      report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v1');
      _checkDeployStamp(step, report, 'v1');
      step.notes.add(requestSources(chrome));
      await chrome.close();
    } finally {
      await host.stop();
    }
  }
}

/// What `flutter_bootstrap.js` did before flutter/flutter#176834: register
/// `flutter_service_worker.js?v=<random>` on every load. Today's loader only
/// *updates* an existing registration, so a fresh install needs the explicit
/// `serviceWorkerUrl`.
const String legacyBootstrapJs = '''
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
    serviceWorkerUrl: 'flutter_service_worker.js?v=' + {{flutter_service_worker_version}},
  },
});
''';

/// S5: the user has the pre-3.38 offline-first service worker installed from
/// a v1 built without content hashing; v2 is a hashed build with the
/// self-unregistering stub worker.
class LegacyServiceWorkerMigrationScenario extends Scenario {
  LegacyServiceWorkerMigrationScenario([this.policy = HeaderPolicy.strict]);

  final HeaderPolicy policy;

  @override
  String get id => 'S5.${policy.name}';
  @override
  String get title => 'migration from the legacy offline-first service worker';
  @override
  String get description =>
      'v1 (no hash, legacy SW) visited twice so the SW is active and serving; v2 (hashed, stub SW) deployed; observe the next visits.';

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final v1 = await ctx.build(
      const BuildOptions(
        version: 'v1',
        contentHash: false,
        legacyServiceWorker: true,
        customBootstrapJs: legacyBootstrapJs,
      ),
    );
    final v2 = await ctx.build(_v2);
    result.builds.addAll([v1.toJson(), v2.toJson()]);
    if (!v1.succeeded || !v2.succeeded) {
      result.error = 'build failed: ${v1.stderr}\n${v2.stderr}';
      return;
    }
    // `strict` isolates the worker from the HTTP cache; `firebaseDefaults`
    // asks whether a cached worker script (max-age=3600) delays migration.
    final host = await ctx.host(policy);
    final profile = ctx.freshProfile(id);
    try {
      await host.deployAtomic(v1.outDir);
      var chrome = await ctx.chrome(profile);
      var step = result.step('first visit v1 (legacy SW installs)');
      var report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v1');
      await chrome.settle(const Duration(seconds: 4));
      step.check(
        'legacy SW activated',
        chrome.serviceWorkers.values.any((v) => v.status == 'activated'),
        chrome.serviceWorkerEvents.join(' | '),
      );
      await chrome.close();

      chrome = await ctx.chrome(profile);
      step = result.step('second visit v1 (served by legacy SW)');
      report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v1');
      final swServed = chrome.requests
          .where((r) => r.fromServiceWorker)
          .map((r) => r.path)
          .toList();
      step.check(
        'entrypoint served from service worker',
        swServed.any((path) => path.contains('main.dart')),
        'from SW: ${swServed.join(', ')}',
      );
      await chrome.close();

      await host.deployAtomic(v2.outDir);
      chrome = await ctx.chrome(profile);
      step = result.step('third visit: v2 deployed, legacy SW still installed');
      report = await loadAndCapture(step, chrome, host, host.baseUri);
      final firstSeen = report?['version'];
      step.notes.add(
        'first render reported version=$firstSeen; SW events: ${chrome.serviceWorkerEvents.join(' | ')}',
      );
      // The stub worker should install, unregister, and navigate the client.
      await chrome.settle(const Duration(seconds: 6));
      final after = await chrome.waitForAppReport(
        timeout: const Duration(seconds: 20),
        expectedVersion: 'v2',
      );
      step.capture(chrome, host, after);
      step.check(
        'user ends up on v2 within ~25s',
        after?['version'] == 'v2',
        'first=$firstSeen final=${after?['version']}',
      );
      step.check(
        'no legacy SW left activated',
        !chrome.serviceWorkers.values.any(
          (v) => v.status == 'activated' && v.runningStatus != 'stopped',
        ),
        chrome.serviceWorkers.values
            .map((v) => '${v.status}/${v.runningStatus}')
            .join(', '),
      );
      step.notes.add(requestSources(chrome));
      await chrome.close();

      chrome = await ctx.chrome(profile);
      step = result.step('fourth visit');
      report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v2');
      // Watch for a register → unregister → navigate loop driven by a still
      // cached legacy bootstrap.
      await chrome.settle(const Duration(seconds: 10));
      final finalReport = await chrome.waitForAppReport(
        timeout: const Duration(seconds: 5),
      );
      step.capture(chrome, host, finalReport);
      final installs = chrome.serviceWorkerEvents
          .where((e) => e.endsWith('installing/running'))
          .length;
      step.check(
        'no reload loop (≤1 navigation in 10 s after load)',
        chrome.navigations <= 1,
        'navigations=${chrome.navigations} worker installs=$installs',
      );
      step.check(
        'nothing served from a service worker',
        chrome.requests.every((r) => !r.fromServiceWorker),
        requestSources(chrome),
      );
      step.notes.add(
        'SW events: ${chrome.serviceWorkerEvents.join(' > ')}'.substring(
          0,
          300 > chrome.serviceWorkerEvents.join(' > ').length + 11
              ? chrome.serviceWorkerEvents.join(' > ').length + 11
              : 300,
        ),
      );
      await chrome.close();
    } finally {
      await host.stop();
    }
  }
}

/// S6: a CDN edge keeps serving the old `index.html` for a while after the
/// origin was atomically replaced (old hashed files are gone).
class CdnStaleIndexScenario extends Scenario {
  @override
  String get id => 'S6';
  @override
  String get title => 'CDN serves stale index.html after an atomic deploy';
  @override
  String get description =>
      'Old index → old flutter_bootstrap? → old hash that no longer exists at origin.';

  @override
  Future<void> run(ScenarioContext ctx, ScenarioResult result) async {
    final v1 = await ctx.build(_v1);
    final v2 = await ctx.build(_v2);
    result.builds.addAll([v1.toJson(), v2.toJson()]);
    if (!v1.succeeded || !v2.succeeded) {
      result.error = 'build failed';
      return;
    }
    final host = await ctx.host(
      HeaderPolicy.strict,
      cdnIndexTtl: const Duration(seconds: 60),
    );
    final profile = ctx.freshProfile(id);
    try {
      await host.deployAtomic(v1.outDir);
      final chrome = await ctx.chrome(profile);
      var step = result.step('visit v1');
      var report = await loadAndCapture(step, chrome, host, host.baseUri);
      checkHealthyLoad(step, chrome, report, expectedVersion: 'v1');

      await host.deployAtomic(v2.outDir);
      step = result.step('visit while the edge still serves v1 index.html');
      report = await loadAndCapture(
        step,
        chrome,
        host,
        host.baseUri,
        timeout: const Duration(seconds: 15),
      );
      step.check(
        'app booted',
        report != null,
        report == null ? 'blank screen' : 'version ${report['version']}',
      );
      step.check(
        'no failed requests',
        chrome.requests.every(
          (r) => r.failure == null && (r.status ?? 0) < 400,
        ),
        failedRequestsSummary(chrome),
      );
      step.notes.add(requestSources(chrome));
      step.notes.add(
        'live files: ${host.liveFiles().where((f) => f.startsWith('main.dart')).join(', ')}',
      );
      await chrome.close();
    } finally {
      await host.stop();
    }
  }
}

String describeBuild(BuildResult b) =>
    '${b.sdk.label} ${b.options.key} → ${p.basename(b.outDir.path)}';
