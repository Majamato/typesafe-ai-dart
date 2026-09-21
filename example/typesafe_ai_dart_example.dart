// ignore_for_file: avoid_print, this is an example.
// Run with: TYPESAFE_API_KEY=... dart run example/typesafe_ai_dart_example.dart
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

enum Department { billing, technical, other }

// Build question handles once, outside the request path. Each encodes
// itself when built and reuses those bytes in every request. Ids are
// for your code; the model only sees the instructions and criteria.
final TypedChoice<Department> department = Choice.fromEnum(
  id: 'department',
  instructions: 'Which department should handle `ticket`?',
  values: Department.values,
  describe: (d) => switch (d) {
    Department.billing => 'charges, refunds, invoices',
    Department.technical => 'bugs, outages, login problems',
    Department.other => null,
  },
);
final isAngry = Noul(
  id: 'isAngry',
  instructions: 'Is the author of `ticket` angry?',
  criteria: NoulCriteria(
    whenTrue: 'threats, insults or ultimatums',
    whenFalse: 'neutral or polite wording, even if firm',
  ),
);
final urgency = Score(
  id: 'urgency',
  instructions: 'How urgent is `ticket`?',
  criteria: const [
    ScoreLevel(summary: 'No deadline, informational'),
    ScoreLevel(summary: 'Wants an answer this week'),
    ScoreLevel(summary: 'Needs action today', signals: ['today', 'now']),
  ],
);

Future<void> main() async {
  // One client per process; on a server, share it across handlers.
  final client = TypeSafeClient();

  final ticket = {
    'ticket': 'I was charged twice this month. Fix it today or I cancel.',
  };

  try {
    final response = await client.systemOne(
      state: ticket,
      questions: [department, isAngry, urgency],
    );

    // Each handle returns its own answer type. No casts.
    final dept = response.answer(department);
    final angry = response.answer(isAngry);
    final urgent = response.answer(urgency);

    print('model:      ${response.model}');
    print(
      'department: ${dept.selected.name} '
      '(confidence ${dept.confidence.toStringAsFixed(2)})',
    );
    print('angry:      ${angry.noul.toStringAsFixed(2)}');
    print(
      'urgency:    ${urgent.score.toStringAsFixed(2)} '
      '(most likely level ${urgent.mostLikelyLevel})',
    );
    print('usage:      ${response.usage.inputTokens} input tokens');
  } on RateLimitException catch (e) {
    print('Rate limited, retry after ${e.retryAfter}');
  } on TypeSafeApiException catch (e) {
    print('API error ${e.statusCode}: ${e.message} (request ${e.requestId})');
  } on TypeSafeConnectionException catch (e) {
    print('Network problem: ${e.message}');
  } finally {
    client.close();
  }
}
