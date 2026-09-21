// Mutation smoke test: applies each mutant in mutants.dart to a scratch copy
// of the package and checks that the test suite then fails.
//
//   dart run tool/mutation/run.dart [--jobs 3] [--only id,id]
//
// Needs `cp` (Linux or macOS). Exits 1 if any mutant survives or is invalid.
// ignore_for_file: avoid_print, this is a command-line tool.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mutants.dart';

/// What the suite made of one mutant.
enum Verdict { killed, survived, timedOut, invalid }

/// Paths copied into each scratch package; everything a test run reads.
const _copied = [
  'lib',
  'test',
  'pubspec.yaml',
  'pubspec.lock',
  'analysis_options.yaml',
  'dart_test.yaml',
  '.dart_tool/package_config.json',
  '.dart_tool/package_graph.json',
];

/// Everything but the live, subprocess and mutation tests; stress is skipped
/// by `dart_test.yaml`.
const _testArgs = ['test', '-x', 'live', '-x', 'subprocess', '-x', 'mutation'];

const _perMutant = Duration(minutes: 3);

Future<void> main(List<String> args) async {
  final jobs = _option(args, '--jobs', '3');
  final only = _option(args, '--only', '');
  final selected = only.isEmpty
      ? mutants
      : [
          for (final m in mutants)
            if (only.split(',').contains(m.id)) m,
        ];
  final root = Directory.current.path;
  final verdicts = <String, (Verdict, String)>{};
  final queue = [...selected];

  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final mutant = queue.removeAt(0);
      final result = await _judge(root, mutant);
      verdicts[mutant.id] = result;
      print('${result.$1.name.padRight(9)} ${mutant.id}');
    }
  }

  await Future.wait([for (var i = 0; i < int.parse(jobs); i++) worker()]);

  final bad = [
    for (final m in selected)
      if (verdicts[m.id]!.$1 case Verdict.survived || Verdict.invalid) m,
  ];
  print('\n${selected.length - bad.length}/${selected.length} mutants killed');
  for (final m in bad) {
    final (verdict, detail) = verdicts[m.id]!;
    print('  ${verdict.name}: ${m.id} (${m.why}) $detail');
  }
  exit(bad.isEmpty ? 0 : 1);
}

Future<(Verdict, String)> _judge(String root, Mutant mutant) async {
  final dir = await Directory.systemTemp.createTemp('typesafe_mutant_');
  try {
    await Directory('${dir.path}/.dart_tool').create();
    for (final path in _copied) {
      if (FileSystemEntity.typeSync('$root/$path') ==
          FileSystemEntityType.notFound) {
        continue;
      }
      final target = path.contains('/') ? '${dir.path}/$path' : dir.path;
      final copy = await Process.run('cp', ['-a', '$root/$path', target]);
      if (copy.exitCode != 0) {
        return (Verdict.invalid, 'copy failed: ${copy.stderr}');
      }
    }
    final file = File('${dir.path}/${mutant.file}');
    final source = await file.readAsString();
    final count = mutant.from.allMatches(source).length;
    if (count != 1) {
      return (Verdict.invalid, '"from" occurs $count times');
    }
    await file.writeAsString(source.replaceFirst(mutant.from, mutant.to));

    final process = await Process.start(
      Platform.resolvedExecutable,
      _testArgs,
      workingDirectory: dir.path,
    );
    final output = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(output.write);
    process.stderr.transform(utf8.decoder).listen(output.write);
    final exitCode = await process.exitCode.timeout(
      _perMutant,
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (exitCode == -1) {
      return (Verdict.timedOut, '');
    }
    if ('$output'.contains('Failed to load')) {
      return (Verdict.invalid, 'does not compile');
    }
    return exitCode == 0 ? (Verdict.survived, '') : (Verdict.killed, '');
  } finally {
    await dir.delete(recursive: true);
  }
}

String _option(List<String> args, String name, String fallback) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
}
