import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'builder.dart';
import 'chrome.dart';
import 'hosting.dart';

/// One assertion inside a step.
class Check {
  Check(this.name, this.passed, [this.detail = '']);

  final String name;
  final bool passed;
  final String detail;

  Map<String, Object?> toJson() => {
    'name': name,
    'passed': passed,
    'detail': detail,
  };
}

/// One observable action (a page load, a deploy) with what the browser and
/// host saw during it.
class Step {
  Step(this.title);

  final String title;
  final List<Check> checks = <Check>[];
  final List<String> notes = <String>[];
  Map<String, Object?>? browser;
  Map<String, Object?>? host;
  Map<String, Object?>? appReport;

  bool get passed => checks.every((c) => c.passed);

  void check(String name, bool passed, [String detail = '']) =>
      checks.add(Check(name, passed, detail));

  /// Captures browser + host evidence and the app's own report.
  void capture(
    ChromeSession chrome,
    HostingServer host,
    Map<String, Object?>? report,
  ) {
    browser = chrome.snapshot();
    this.host = host.snapshot();
    appReport = report;
  }

  Map<String, Object?> toJson() => {
    'title': title,
    'passed': passed,
    'checks': checks.map((c) => c.toJson()).toList(),
    'notes': notes,
    'appReport': appReport,
    'browser': browser,
    'host': host,
  };
}

enum Verdict { pass, fail, blocked }

class ScenarioResult {
  ScenarioResult({required this.id, required this.title, required this.sdk});

  final String id;
  final String title;
  final String sdk;
  final List<Step> steps = <Step>[];
  String? error;
  final List<Map<String, Object?>> builds = <Map<String, Object?>>[];

  Verdict get verdict {
    if (error != null) return Verdict.blocked;
    return steps.every((s) => s.passed) ? Verdict.pass : Verdict.fail;
  }

  Step step(String title) {
    final s = Step(title);
    steps.add(s);
    return s;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'sdk': sdk,
    'verdict': verdict.name,
    'error': error,
    'builds': builds,
    'steps': steps.map((s) => s.toJson()).toList(),
  };
}

/// Shared services for a scenario run.
class ScenarioContext {
  ScenarioContext({
    required this.sdk,
    required this.builder,
    required this.workDir,
    this.headless = true,
  });

  final FlutterSdk sdk;
  final Builder builder;
  final Directory workDir;
  final bool headless;
  int _profileCounter = 0;

  Future<BuildResult> build(BuildOptions options) =>
      builder.build(sdk, options);

  /// A brand-new browser profile: a first-time visitor.
  Directory freshProfile(String label) {
    final dir = Directory(
      p.join(workDir.path, 'profiles', '${label}_${_profileCounter++}'),
    );
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    return dir;
  }

  Future<ChromeSession> chrome(Directory profile) =>
      ChromeSession.launch(profileDir: profile, headless: headless);

  Future<HostingServer> host(
    HeaderPolicy policy, {
    Duration cdnIndexTtl = Duration.zero,
    bool spaRewrite = false,
    String basePath = '/',
    Duration negativeCacheTtl = Duration.zero,
  }) async {
    final server = HostingServer(
      policy: policy,
      cdnIndexTtl: cdnIndexTtl,
      spaRewrite: spaRewrite,
      basePath: basePath,
      negativeCacheTtl: negativeCacheTtl,
    );
    await server.start();
    return server;
  }
}

abstract class Scenario {
  String get id;
  String get title;
  String get description;

  Future<void> run(ScenarioContext ctx, ScenarioResult result);

  Future<ScenarioResult> execute(ScenarioContext ctx) async {
    final result = ScenarioResult(id: id, title: title, sdk: ctx.sdk.label);
    try {
      await run(ctx, result);
    } catch (e, st) {
      result.error = '$e\n$st';
    }
    return result;
  }
}

// --- helpers shared by scenarios ------------------------------------------

/// Loads [url] in [chrome], waits for the app, and records a step.
Future<Map<String, Object?>?> loadAndCapture(
  Step step,
  ChromeSession chrome,
  HostingServer host,
  Uri url, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  chrome.resetObservations();
  host.log.clear();
  await chrome.navigate(url.toString());
  final report = await chrome.waitForAppReport(timeout: timeout);
  await chrome.settle(const Duration(milliseconds: 500));
  step.capture(chrome, host, report);
  return report;
}

/// Standard checks after a load: app booted, reports the expected version,
/// every asset loaded, no failed requests.
void checkHealthyLoad(
  Step step,
  ChromeSession chrome,
  Map<String, Object?>? report, {
  required String expectedVersion,
}) {
  step.check(
    'app booted',
    report != null,
    report == null ? 'no window.__redteam.done within timeout' : '',
  );
  if (report == null) {
    step.check(
      'no failed requests',
      chrome.requests
          .where((r) => r.failure != null || (r.status ?? 0) >= 400)
          .isEmpty,
      failedRequestsSummary(chrome),
    );
    return;
  }
  step.check(
    'version is $expectedVersion',
    report['version'] == expectedVersion,
    'app reported ${report['version']}',
  );
  final assets = (report['assets'] as Map<String, Object?>?) ?? const {};
  final failed = assets.entries
      .where((e) => (e.value as Map<String, Object?>)['ok'] != true)
      .map((e) => e.key)
      .toList();
  step.check(
    'all ${assets.length} assets loaded',
    failed.isEmpty,
    failed.isEmpty ? '' : 'failed: ${failed.join(', ')}',
  );
  final bad = chrome.requests
      .where((r) => r.failure != null || (r.status ?? 0) >= 400)
      .toList();
  step.check('no failed requests', bad.isEmpty, failedRequestsSummary(chrome));
  step.check(
    'no console errors',
    chrome.consoleErrors.isEmpty,
    chrome.consoleErrors.take(5).join(' | '),
  );
}

String failedRequestsSummary(ChromeSession chrome) => chrome.requests
    .where((r) => r.failure != null || (r.status ?? 0) >= 400)
    .map((r) => '${r.path} → ${r.status ?? r.failure}')
    .take(8)
    .join(', ');

/// `path → source` for the interesting requests of a load.
String requestSources(ChromeSession chrome) => chrome.requests
    .where((r) => !r.path.contains('/canvaskit/'))
    .map((r) => '${r.path}=${r.source}')
    .join(', ');

// --- reporting --------------------------------------------------------------

class ReportWriter {
  ReportWriter(this.outDir);

  final Directory outDir;

  Future<void> write(
    List<ScenarioResult> results, {
    required Map<String, String> sdkVersions,
  }) async {
    outDir.createSync(recursive: true);
    File(p.join(outDir.path, 'results.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'sdks': sdkVersions,
        'results': results.map((r) => r.toJson()).toList(),
      }),
    );
    File(p.join(outDir.path, 'summary.md'))
        .writeAsStringSync(markdown(results, sdkVersions));
  }

  static String markdown(
    List<ScenarioResult> results,
    Map<String, String> sdkVersions,
  ) {
    final b = StringBuffer('# Red-team run\n\n');
    for (final e in sdkVersions.entries) {
      b.writeln('- `${e.key}`: ${e.value}');
    }
    b.writeln('\n| Scenario | SDK | Verdict | Failing checks |');
    b.writeln('| :--- | :--- | :--- | :--- |');
    for (final r in results) {
      final failing = r.steps
          .expand(
            (s) => s.checks
                .where((c) => !c.passed)
                .map((c) => '${s.title}: ${c.name}'),
          )
          .join('; ');
      b.writeln(
        '| ${r.id} ${r.title} | ${r.sdk} | ${r.verdict.name.toUpperCase()} | ${r.error != null ? 'BLOCKED: ${r.error!.split('\n').first}' : failing} |',
      );
    }
    for (final r in results) {
      b.writeln(
        '\n## ${r.id} ${r.title} (`${r.sdk}`) — ${r.verdict.name.toUpperCase()}\n',
      );
      for (final s in r.steps) {
        b.writeln('### ${s.passed ? '✅' : '❌'} ${s.title}\n');
        for (final c in s.checks) {
          b.writeln(
            '- ${c.passed ? '✅' : '❌'} ${c.name}${c.detail.isEmpty ? '' : ' — ${c.detail}'}',
          );
        }
        for (final n in s.notes) {
          b.writeln('- ℹ️ $n');
        }
        b.writeln();
      }
      if (r.error != null) b.writeln('```\n${r.error}\n```');
    }
    return b.toString();
  }
}
