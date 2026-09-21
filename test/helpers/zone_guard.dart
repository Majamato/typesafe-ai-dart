import 'dart:async';

import 'package:test/test.dart';

/// Runs [body] in its own error zone and fails if any error escapes it
/// uncaught, including ones raised during a [settle] period afterwards.
Future<T> expectNoUncaughtErrors<T>(
  Future<T> Function() body, {
  Duration settle = const Duration(milliseconds: 50),
}) async {
  final uncaught = <(Object, StackTrace)>[];
  final done = Completer<T>();
  unawaited(
    runZonedGuarded(() async {
      try {
        final result = await body();
        await Future<void>.delayed(settle);
        done.complete(result);
      } on Object catch (error, stackTrace) {
        done.completeError(error, stackTrace);
      }
    }, (error, stackTrace) => uncaught.add((error, stackTrace))),
  );
  final result = await done.future;
  if (uncaught.isNotEmpty) {
    final (error, stackTrace) = uncaught.first;
    fail(
      '${uncaught.length} uncaught async error(s); first: $error\n$stackTrace',
    );
  }
  return result;
}
