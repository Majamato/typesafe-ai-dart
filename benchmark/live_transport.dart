// ignore_for_file: avoid_print, this is a benchmark script.
// Compares the default HTTP/1.1 client with `http2: true` against the real
// API under concurrency, using GET /v1/models so no tokens are spent.
//
// TYPESAFE_API_KEY=... dart run benchmark/live_transport.dart [conc] [rounds]
import 'dart:io';

import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

Future<void> main(List<String> args) async {
  if ((Platform.environment[ClientConfig.apiKeyVariable] ?? '').isEmpty) {
    print('Set ${ClientConfig.apiKeyVariable} to run this benchmark.');
    exitCode = 64;
    return;
  }
  final concurrency = args.isNotEmpty ? int.parse(args[0]) : 16;
  final rounds = args.length > 1 ? int.parse(args[1]) : 5;
  print('$concurrency concurrent calls x $rounds rounds\n');

  const transports = [
    ('HTTP/1.1 (default)', false),
    ('HTTP/2 (http2: true)', true),
  ];
  // One throwaway call per transport first, so neither measured run pays for
  // DNS, JIT or first-TLS warm-up; whichever ran first otherwise lost
  // 100-250 ms of cold latency.
  for (final (_, http2) in transports) {
    final warmUp = TypeSafeClient(http2: http2);
    await warmUp.listModels();
    warmUp.close();
  }

  for (final (name, http2) in transports) {
    final client = TypeSafeClient(http2: http2, retryPolicy: RetryPolicy.none);
    final cold = <int>[];
    final warm = <int>[];
    final wall = Stopwatch()..start();
    for (var round = 0; round < rounds; round++) {
      await Future.wait([
        for (var i = 0; i < concurrency; i++)
          _timed(client.listModels, round == 0 ? cold : warm),
      ]);
    }
    wall.stop();
    client.close();
    print(
      '${name.padRight(22)} cold p50 ${_ms(cold, 0.5)}  '
      'warm p50 ${_ms(warm, 0.5)}  p99 ${_ms(warm, 0.99)}  '
      'total ${wall.elapsedMilliseconds} ms',
    );
  }
}

Future<void> _timed(Future<Object?> Function() call, List<int> into) async {
  final stopwatch = Stopwatch()..start();
  await call();
  into.add(stopwatch.elapsedMicroseconds);
}

String _ms(List<int> micros, double quantile) {
  if (micros.isEmpty) {
    return '     -';
  }
  final sorted = [...micros]..sort();
  final index = ((sorted.length - 1) * quantile).round();
  return '${(sorted[index] / 1000).toStringAsFixed(0).padLeft(4)} ms';
}
