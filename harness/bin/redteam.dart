import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:redteam_harness/redteam_harness.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('list', negatable: false, help: 'List scenarios and exit.')
    ..addMultiOption(
      'sdk',
      defaultsTo: ['master'],
      help: 'master and/or phase3.',
    )
    ..addMultiOption(
      'scenario',
      abbr: 's',
      help: 'Scenario ids (prefix match). Default: all.',
    )
    ..addOption(
      'out',
      abbr: 'o',
      help: 'Results directory (default: results/<timestamp>).',
    )
    ..addOption(
      'work',
      help: 'Scratch directory for builds/profiles (default: /tmp).',
    )
    ..addFlag('headed', negatable: false, help: 'Run Chromium with a window.');
  final args = parser.parse(argv);
  if (args['help'] as bool) {
    stdout.writeln(
      'Usage: dart run bin/redteam.dart [options]\n${parser.usage}',
    );
    return;
  }

  final scenarios = allScenarios();
  if (args['list'] as bool) {
    for (final s in scenarios) {
      stdout.writeln(
        '${s.id.padRight(24)} ${s.title}\n${' ' * 25}${s.description}',
      );
    }
    return;
  }

  final wanted = args['scenario'] as List<String>;
  final selected = wanted.isEmpty
      ? scenarios
      : scenarios
            .where(
              (s) => wanted.any((w) => s.id == w || s.id.startsWith('$w.')),
            )
            .toList();
  if (selected.isEmpty) {
    stderr.writeln('No scenario matches $wanted. Use --list.');
    exit(64);
  }

  final repoRoot = _findRepoRoot();
  final workDir = Directory(
    args['work'] as String? ??
        p.join(Directory.systemTemp.path, 'redteam_work'),
  );
  final outDir = Directory(
    args['out'] as String? ??
        p.join(
          repoRoot.path,
          'results',
          DateTime.now()
              .toUtc()
              .toIso8601String()
              .replaceAll(':', '-')
              .split('.')
              .first,
        ),
  );
  final builder = Builder(
    sampleAppDir: Directory(p.join(repoRoot.path, 'sample_app')),
    workDir: workDir,
  );

  final results = <ScenarioResult>[];
  final sdkVersions = <String, String>{};
  for (final label in args['sdk'] as List<String>) {
    final sdk = FlutterSdk.byLabel(label);
    if (!File(sdk.flutterBin).existsSync()) {
      stderr.writeln('SDK $label not found at ${sdk.root.path}');
      exit(1);
    }
    sdkVersions[label] = await sdk.version();
    stdout.writeln('== SDK $label: ${sdkVersions[label]}');
    final ctx = ScenarioContext(
      sdk: sdk,
      builder: builder,
      workDir: workDir,
      headless: !(args['headed'] as bool),
    );
    for (final scenario in selected) {
      stdout.write('-- ${scenario.id} ${scenario.title} ... ');
      final started = DateTime.now();
      final result = await scenario.execute(ctx);
      results.add(result);
      stdout.writeln(
        '${result.verdict.name.toUpperCase()} (${DateTime.now().difference(started).inSeconds}s)',
      );
      for (final step in result.steps) {
        for (final c in step.checks.where((c) => !c.passed)) {
          stdout.writeln(
            '     ✗ ${step.title}: ${c.name}${c.detail.isEmpty ? '' : ' — ${c.detail}'}',
          );
        }
      }
      if (result.error != null) {
        stdout.writeln('     ! ${result.error!.split('\n').first}');
      }
      // Persist after every scenario so a crash keeps partial evidence.
      await ReportWriter(outDir).write(results, sdkVersions: sdkVersions);
    }
  }
  stdout.writeln('\nResults: ${outDir.path}/summary.md');
}

Directory _findRepoRoot() {
  var dir = Directory.current;
  while (!Directory(p.join(dir.path, 'sample_app')).existsSync()) {
    if (dir.parent.path == dir.path) {
      throw StateError('Run from inside the flutter_web_cache_redteam repo.');
    }
    dir = dir.parent;
  }
  return dir;
}
