import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';

/// Seed of every property test: `TYPESAFE_FUZZ_SEED`, else fixed so a
/// failure reproduces on the next run.
final int fuzzSeed =
    int.tryParse(Platform.environment['TYPESAFE_FUZZ_SEED'] ?? '') ?? 20260924;

/// Cases per property: `TYPESAFE_FUZZ_RUNS`, else [defaultRuns].
int fuzzRuns([int defaultRuns = 200]) =>
    int.tryParse(Platform.environment['TYPESAFE_FUZZ_RUNS'] ?? '') ??
    defaultRuns;

/// Checks [check] against [runs] inputs from [generate], each from its own
/// seeded [Random]; a failure names the seed, run and [describe]d input.
Future<void> forAll<T>(
  T Function(Random random) generate,
  FutureOr<void> Function(T input) check, {
  int? runs,
  String Function(T input)? describe,
}) async {
  final total = runs ?? fuzzRuns();
  for (var run = 0; run < total; run++) {
    final input = generate(Random(fuzzSeed * 1000003 + run));
    try {
      await check(input);
    } on Object catch (error, stackTrace) {
      final shown = truncate((describe ?? _show)(input));
      Error.throwWithStackTrace(
        TestFailure(
          'Property failed at TYPESAFE_FUZZ_SEED=$fuzzSeed, run $run '
          '(of $total)\ninput: $shown\n$error',
        ),
        stackTrace,
      );
    }
  }
}

/// Returns [text] cut to [max] characters, marking how much was dropped.
String truncate(String text, [int max = 600]) => text.length <= max
    ? text
    : '${text.substring(0, max)}… (${text.length - max} more chars)';

String _show(Object? input) {
  try {
    return '$input';
  } on Object catch (e) {
    return '<unprintable: $e>';
  }
}
