import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

/// One network request as observed by the browser (Chrome DevTools Protocol).
class RequestRecord {
  RequestRecord({
    required this.requestId,
    required this.url,
    required this.method,
  });

  final String requestId;
  final String url;
  final String method;
  int? status;
  String? mimeType;
  String? cacheControl;
  bool fromDiskCache = false;
  bool fromServiceWorker = false;
  bool fromMemoryCache = false;
  String? failure;

  String get path => Uri.parse(url).path;

  /// Where the bytes came from, as a short label for reports.
  String get source {
    if (failure != null) return 'FAILED(${failure!})';
    if (fromServiceWorker) return 'service-worker';
    if (fromMemoryCache) return 'memory-cache';
    if (fromDiskCache) return 'disk-cache';
    if (status == 304) return 'revalidated-304';
    return 'network';
  }

  Map<String, Object?> toJson() => {
    'url': url,
    'method': method,
    'status': status,
    'source': source,
    'cacheControl': cacheControl,
    'mimeType': mimeType,
  };
}

/// A service worker version as reported by `ServiceWorker.workerVersionUpdated`.
class ServiceWorkerVersion {
  ServiceWorkerVersion(
    this.versionId,
    this.scriptUrl,
    this.status,
    this.runningStatus,
  );

  final String versionId;
  final String scriptUrl;
  final String status;
  final String runningStatus;

  Map<String, Object?> toJson() => {
    'versionId': versionId,
    'scriptUrl': scriptUrl,
    'status': status,
    'runningStatus': runningStatus,
  };
}

/// Resolves a Chromium binary: `$REDTEAM_CHROME`, then Playwright's download,
/// then a system Chrome.
String resolveChromeBinary() {
  final env = Platform.environment['REDTEAM_CHROME'];
  if (env != null && File(env).existsSync()) return env;
  final home = Platform.environment['HOME'] ?? '';
  final playwright = Directory(p.join(home, '.cache', 'ms-playwright'));
  if (playwright.existsSync()) {
    final candidates =
        playwright
            .listSync()
            .whereType<Directory>()
            .where((d) => p.basename(d.path).startsWith('chromium-'))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    for (final dir in candidates) {
      for (final rel in ['chrome-linux/chrome', 'chrome-linux64/chrome']) {
        final f = File(p.join(dir.path, rel));
        if (f.existsSync()) return f.path;
      }
    }
  }
  for (final sys in [
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ]) {
    if (File(sys).existsSync()) return sys;
  }
  throw StateError('No Chromium found. Set REDTEAM_CHROME=/path/to/chrome.');
}

/// A headless Chromium with a persistent profile directory, driven over CDP.
///
/// The profile directory is the unit of "warm cache": launching again with the
/// same directory reuses the HTTP disk cache and any installed service worker,
/// exactly like a returning user.
class ChromeSession {
  ChromeSession._(
    this._process,
    this._page,
    this._browser,
    this.profileDir,
    this._devtoolsPort,
  );

  final Process _process;
  final WipConnection _page;
  final WipConnection _browser;
  final Directory profileDir;
  final int _devtoolsPort;

  final List<RequestRecord> requests = <RequestRecord>[];
  final Map<String, RequestRecord> _byId = <String, RequestRecord>{};
  final List<String> consoleErrors = <String>[];
  final List<String> consoleMessages = <String>[];
  final List<String> logEntries = <String>[];
  final Map<String, ServiceWorkerVersion> serviceWorkers =
      <String, ServiceWorkerVersion>{};
  final List<String> serviceWorkerEvents = <String>[];

  /// Top-level navigations since the last [resetObservations] (1 = the load
  /// itself; more = the page reloaded itself, e.g. a service worker
  /// calling `client.navigate()`).
  int navigations = 0;

  static Future<ChromeSession> launch({
    required Directory profileDir,
    bool headless = true,
  }) async {
    profileDir.createSync(recursive: true);
    // A previous Chromium on this profile leaves its port file behind; a
    // fresh launch must not read the stale one.
    final stalePort = File(p.join(profileDir.path, 'DevToolsActivePort'));
    if (stalePort.existsSync()) stalePort.deleteSync();
    final chrome = resolveChromeBinary();
    final process = await Process.start(chrome, [
      '--remote-debugging-port=0',
      '--remote-allow-origins=*',
      if (headless) '--headless=new',
      '--no-sandbox',
      '--disable-dev-shm-usage',
      '--disable-extensions',
      '--disable-background-networking',
      '--disable-background-timer-throttling',
      '--disable-renderer-backgrounding',
      '--disable-sync',
      '--no-first-run',
      '--no-default-browser-check',
      '--no-proxy-server',
      '--password-store=basic',
      '--use-mock-keychain',
      '--user-data-dir=${profileDir.path}',
      'about:blank',
    ]);
    // Drain output so Chrome never blocks on a full pipe.
    process.stdout.drain<void>();
    process.stderr.drain<void>();

    final port = await _waitForDevToolsPort(profileDir, process);
    final targets = await _listTargets(port);
    final page = targets.firstWhere(
      (t) => t['type'] == 'page',
      orElse: () => throw StateError('No page target: $targets'),
    );
    final browserVersion = json.decode(
      (await http.get(Uri.parse('http://127.0.0.1:$port/json/version'))).body,
    ) as Map<String, Object?>;
    final pageConn = await WipConnection.connect(
      page['webSocketDebuggerUrl'] as String,
    );
    final browserConn = await WipConnection.connect(
      browserVersion['webSocketDebuggerUrl'] as String,
    );
    final session = ChromeSession._(
      process,
      pageConn,
      browserConn,
      profileDir,
      port,
    );
    await session._enableDomains();
    return session;
  }

  static Future<int> _waitForDevToolsPort(
    Directory profileDir,
    Process process,
  ) async {
    final portFile = File(p.join(profileDir.path, 'DevToolsActivePort'));
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (portFile.existsSync()) {
        final lines = portFile.readAsLinesSync();
        if (lines.isNotEmpty) {
          final port = int.tryParse(lines.first.trim());
          if (port != null && port > 0) return port;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    process.kill();
    throw StateError(
      'Chrome did not publish DevToolsActivePort in ${profileDir.path}',
    );
  }

  static Future<List<Map<String, Object?>>> _listTargets(int port) async {
    final resp = await http.get(Uri.parse('http://127.0.0.1:$port/json'));
    return (json.decode(resp.body) as List<Object?>)
        .cast<Map<String, Object?>>();
  }

  Future<void> _enableDomains() async {
    _page.onNotification.listen(_onNotification);
    await _page.sendCommand('Network.enable');
    await _page.sendCommand('Page.enable');
    await _page.sendCommand('Runtime.enable');
    await _page.sendCommand('Log.enable');
    await _page.sendCommand('ServiceWorker.enable');
  }

  void _onNotification(WipEvent event) {
    final params = event.params ?? const <String, Object?>{};
    switch (event.method) {
      case 'Network.requestWillBeSent':
        final id = params['requestId'] as String;
        final request = params['request'] as Map<String, Object?>;
        final rec = RequestRecord(
          requestId: id,
          url: request['url'] as String,
          method: request['method'] as String,
        );
        _byId[id] = rec;
        requests.add(rec);
      case 'Network.responseReceived':
        final rec = _byId[params['requestId'] as String];
        if (rec == null) return;
        final response = params['response'] as Map<String, Object?>;
        rec.status = response['status'] as int?;
        rec.mimeType = response['mimeType'] as String?;
        rec.fromDiskCache = response['fromDiskCache'] == true;
        rec.fromServiceWorker = response['fromServiceWorker'] == true;
        final headers =
            (response['headers'] as Map<String, Object?>?) ?? const {};
        for (final entry in headers.entries) {
          if (entry.key.toLowerCase() == 'cache-control') {
            rec.cacheControl = entry.value as String?;
          }
        }
      case 'Network.requestServedFromCache':
        _byId[params['requestId'] as String]?.fromMemoryCache = true;
      case 'Network.loadingFailed':
        final rec = _byId[params['requestId'] as String];
        final errorText = params['errorText'] as String?;
        // A fetch the page itself cancelled (duplicate font/asset requests
        // during boot) is not a delivery failure.
        if (rec != null && errorText != 'net::ERR_ABORTED') {
          rec.failure = errorText;
        }
      case 'Runtime.consoleAPICalled':
        final type = params['type'] as String;
        final args = (params['args'] as List<Object?>? ?? const [])
            .cast<Map<String, Object?>>()
            .map(
              (a) =>
                  a['value']?.toString() ?? a['description']?.toString() ?? '',
            )
            .join(' ');
        consoleMessages.add('[$type] $args');
        if (type == 'error') consoleErrors.add(args);
      case 'Runtime.exceptionThrown':
        final details = params['exceptionDetails'] as Map<String, Object?>;
        final exception = details['exception'] as Map<String, Object?>?;
        consoleErrors.add(
          'uncaught: ${exception?['description'] ?? details['text']}',
        );
      case 'Log.entryAdded':
        final entry = params['entry'] as Map<String, Object?>;
        final line =
            '${entry['level']} ${entry['source']}: ${entry['text']} ${entry['url'] ?? ''}';
        logEntries.add(line);
        if (entry['level'] == 'error') consoleErrors.add(line);
      case 'ServiceWorker.workerVersionUpdated':
        for (final v
            in (params['versions'] as List<Object?>)
                .cast<Map<String, Object?>>()) {
          // Chromium registers its own component-extension workers
          // (chrome-extension://.../thunk.js); only the app's matter.
          if (!(v['scriptURL'] as String).startsWith('http')) continue;
          final version = ServiceWorkerVersion(
            v['versionId'] as String,
            v['scriptURL'] as String,
            v['status'] as String,
            v['runningStatus'] as String,
          );
          serviceWorkers[version.versionId] = version;
          serviceWorkerEvents.add(
            '${version.versionId} ${version.status}/${version.runningStatus}',
          );
        }
      case 'Page.frameNavigated':
        final frame = params['frame'] as Map<String, Object?>;
        if (frame['parentId'] == null) navigations++;
      case 'ServiceWorker.workerErrorReported':
        serviceWorkerEvents.add('ERROR ${params['errorMessage']}');
        consoleErrors.add('service worker error: ${params['errorMessage']}');
    }
  }

  /// Forgets everything observed so far; call before each navigation you
  /// want to attribute evidence to.
  void resetObservations() {
    requests.clear();
    _byId.clear();
    consoleErrors.clear();
    consoleMessages.clear();
    logEntries.clear();
    serviceWorkerEvents.clear();
    navigations = 0;
  }

  Future<void> navigate(String url) async {
    await _page.sendCommand('Page.navigate', {'url': url});
  }

  Future<void> reload({bool ignoreCache = false}) async {
    await _page.sendCommand('Page.reload', {'ignoreCache': ignoreCache});
  }

  /// Evaluates [expression] in the page and returns its JSON-serializable value.
  Future<Object?> evaluate(String expression) async {
    final result = await _page.sendCommand('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });
    final res = result.result ?? const <String, Object?>{};
    final exception = res['exceptionDetails'];
    if (exception != null) {
      throw StateError('evaluate failed: $exception');
    }
    return (res['result'] as Map<String, Object?>?)?['value'];
  }

  /// Polls `window.__redteamJson` (set by the sample app) until it reports
  /// `done: true` or the timeout elapses. Returns null on timeout, which is
  /// itself evidence (blank screen / never booted).
  Future<Map<String, Object?>?> waitForAppReport({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final raw = await evaluate('window.__redteamJson || null');
        if (raw is String) {
          final report = json.decode(raw) as Map<String, Object?>;
          if (report['done'] == true) return report;
        }
      } catch (_) {
        // Page may be mid-navigation.
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  /// Asks the running app to load its lazy asset set (simulates a user
  /// navigating to a screen after a deploy happened underneath them).
  Future<Map<String, Object?>?> triggerLazyLoad({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await evaluate('window.__redteamLoadLazy && window.__redteamLoadLazy()');
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final raw = await evaluate('window.__redteamJson || null');
      if (raw is String) {
        final report = json.decode(raw) as Map<String, Object?>;
        if (report['lazyDone'] == true) return report;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Future<void> setOffline(bool offline) async {
    await _page.sendCommand('Network.emulateNetworkConditions', {
      'offline': offline,
      'latency': 0,
      'downloadThroughput': -1,
      'uploadThroughput': -1,
    });
  }

  Future<void> clearBrowserCache() async {
    await _page.sendCommand('Network.clearBrowserCache');
  }

  /// Lets an in-flight service worker update settle.
  Future<void> settle([Duration d = const Duration(seconds: 2)]) =>
      Future<void>.delayed(d);

  /// Opens a second tab on [url] and returns a session bound to it. The tab
  /// shares this session's profile (cache, service workers).
  Future<ChromeSession> openTab(String url) async {
    final created = await _browser.sendCommand('Target.createTarget', {
      'url': 'about:blank',
    });
    final targetId = created.result!['targetId'] as String;
    final targets = await _listTargets(_devtoolsPort);
    final target = targets.firstWhere((t) => t['id'] == targetId);
    final pageConn = await WipConnection.connect(
      target['webSocketDebuggerUrl'] as String,
    );
    final tab = ChromeSession._(
      _process,
      pageConn,
      _browser,
      profileDir,
      _devtoolsPort,
    );
    await tab._enableDomains();
    await tab.navigate(url);
    return tab;
  }

  /// Closes the browser gracefully so the disk cache is flushed for the next
  /// launch on the same profile.
  Future<void> close() async {
    try {
      await _browser
          .sendCommand('Browser.close')
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      _process.kill();
    }
    final exited = await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (exited == -1) {
      await _process.exitCode;
    }
    try {
      await _page.close();
    } catch (_) {}
    try {
      await _browser.close();
    } catch (_) {}
  }

  /// Evidence snapshot for reports.
  Map<String, Object?> snapshot() => {
    'requests': requests.map((r) => r.toJson()).toList(),
    'consoleErrors': consoleErrors,
    'logEntries': logEntries,
    'serviceWorkers': serviceWorkers.values.map((v) => v.toJson()).toList(),
    'serviceWorkerEvents': serviceWorkerEvents,
    'navigations': navigations,
  };
}
