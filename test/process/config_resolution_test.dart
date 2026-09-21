@Tags(['subprocess'])
library;

import 'dart:convert';

import 'package:test/test.dart';

import 'support.dart';

/// One row of the resolution matrix: what the subprocess sees, and what
/// `ClientConfig.resolve` should make of it.
typedef Case = ({
  String name,
  Map<String, String> env,
  Map<String, String> defines,
  List<String> args,
  Map<String, String>? expected,
  String? error,
});

const _key = 'TYPESAFE_API_KEY';
const _url = 'TYPESAFE_BASE_URL';
const _model = 'TYPESAFE_DEFAULT_MODEL';

Case _case(
  String name, {
  Map<String, String> env = const {},
  Map<String, String> defines = const {},
  List<String> args = const [],
  Map<String, String>? expected,
  String? error,
}) => (
  name: name,
  env: env,
  defines: defines,
  args: args,
  expected: expected,
  error: error,
);

final _cases = <Case>[
  _case('no key anywhere is an error', error: 'No TypeSafe API key'),
  _case(
    'built-in defaults fill what nothing sets',
    env: {_key: 'k-env'},
    expected: {
      'apiKey': 'k-env',
      'baseUrl': 'https://api.typesafe.ai',
      'model': 'jev-latest',
    },
  ),
  _case(
    'a define is used when the env var is unset',
    defines: {_key: 'k-def', _url: 'http://def.test', _model: 'm-def'},
    expected: {
      'apiKey': 'k-def',
      'baseUrl': 'http://def.test',
      'model': 'm-def',
    },
  ),
  _case(
    'the env var beats the define',
    env: {_key: 'k-env', _url: 'http://env.test', _model: 'm-env'},
    defines: {_key: 'k-def', _url: 'http://def.test', _model: 'm-def'},
    expected: {
      'apiKey': 'k-env',
      'baseUrl': 'http://env.test',
      'model': 'm-env',
    },
  ),
  _case(
    'an argument beats the env var and the define',
    env: {_key: 'k-env', _url: 'http://env.test', _model: 'm-env'},
    defines: {_key: 'k-def', _url: 'http://def.test', _model: 'm-def'},
    args: ['apiKey=k-arg', 'baseUrl=http://arg.test', 'model=m-arg'],
    expected: {
      'apiKey': 'k-arg',
      'baseUrl': 'http://arg.test',
      'model': 'm-arg',
    },
  ),
  _case(
    'an empty argument counts as unset',
    env: {_key: 'k-env', _url: 'http://env.test', _model: 'm-env'},
    args: ['apiKey=', 'baseUrl=', 'model='],
    expected: {
      'apiKey': 'k-env',
      'baseUrl': 'http://env.test',
      'model': 'm-env',
    },
  ),
  _case(
    'an empty env var counts as unset',
    env: {_key: '', _url: '', _model: ''},
    defines: {_key: 'k-def', _url: 'http://def.test', _model: 'm-def'},
    expected: {
      'apiKey': 'k-def',
      'baseUrl': 'http://def.test',
      'model': 'm-def',
    },
  ),
  _case(
    'S4: an empty define counts as unset for the base URL and model',
    env: {_key: 'k-env'},
    defines: {_url: '', _model: ''},
    expected: {
      'apiKey': 'k-env',
      'baseUrl': 'https://api.typesafe.ai',
      'model': 'jev-latest',
    },
  ),
  _case(
    'S4: an empty define counts as unset for the key',
    defines: {_key: ''},
    error: 'No TypeSafe API key',
  ),
  _case(
    'trailing slashes from the env var are stripped',
    env: {_key: 'k-env', _url: 'https://env.test/v1///'},
    expected: {
      'apiKey': 'k-env',
      'baseUrl': 'https://env.test/v1',
      'model': 'jev-latest',
    },
  ),
];

void main() {
  for (final c in _cases) {
    test(c.name, () async {
      final result = await runFixture(
        'print_config',
        env: c.env,
        defines: c.defines,
        args: c.args,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final printed =
          jsonDecode((result.stdout as String).trim()) as Map<String, Object?>;
      if (c.error case final error?) {
        expect(printed['error'], contains(error));
      } else {
        expect(printed, c.expected);
      }
    });
  }
}
