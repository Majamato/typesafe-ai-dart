import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/json/json_fields.dart';

Matcher failsAt(String path, {Object? message, Object? actual}) => throwsA(
  isA<ResponseValidationException>()
      .having((e) => e.fieldPath, 'fieldPath', path)
      .having((e) => e.message, 'message', message ?? anything)
      .having((e) => e.actual, 'actual', actual),
);

void main() {
  const json = <String, Object?>{
    'model': 'jev-1.13.0',
    'noul': 1,
    'confidence': 0.9,
    'answers': {'tone': <String, Object?>{}},
    'list': [1, 2.0, 'x'],
    'probabilities': {'calm': 0.25, 'angry': 1},
    'nothing': null,
  };

  test('reads each kind and widens integers to doubles', () {
    expect(readString(json, 'model'), 'jev-1.13.0');
    expect(readDouble(json, 'noul'), 1.0);
    expect(readDouble(json, 'confidence'), 0.9);
    expect(readObject(json, 'answers'), same(json['answers']));
    expect(readList(json, 'list'), same(json['list']));
    expect(readDoubles(json, 'probabilities'), {'calm': 0.25, 'angry': 1.0});
  });

  test('an absent field is missing, not mistyped', () {
    expect(
      () => readString(json, 'absent'),
      failsAt('absent', message: 'Missing required field'),
    );
  });

  test('a mistyped field names the kinds and keeps the value', () {
    expect(
      () => readDouble(json, 'model'),
      failsAt(
        'model',
        message: 'Expected number, got string',
        actual: 'jev-1.13.0',
      ),
    );
    expect(
      () => readObject(json, 'nothing'),
      failsAt('nothing', message: 'Expected object, got null'),
    );
  });

  test('optional strings treat absent and null alike', () {
    expect(readOptionalString(json, 'absent'), isNull);
    expect(readOptionalString(json, 'nothing'), isNull);
    expect(readOptionalString(json, 'model'), 'jev-1.13.0');
    expect(() => readOptionalString(json, 'noul'), failsAt('noul', actual: 1));
  });

  test('a mistyped map value is reported under its key', () {
    expect(
      () => readDoubles(const {
        'probabilities': {'calm': 'high'},
      }, 'probabilities'),
      failsAt('probabilities.calm', actual: 'high'),
    );
  });

  test('nestUnder prefixes relative paths and replaces the root', () {
    const error = ResponseValidationException('x', fieldPath: 'noul');
    expect(nestUnder(error, 'answers.q').fieldPath, 'answers.q.noul');
    const root = ResponseValidationException('x', fieldPath: r'$', actual: 3);
    final nested = nestUnder(root, 'models.0');
    expect(nested.fieldPath, 'models.0');
    expect(nested.actual, 3);
    expect(nested.message, 'x');
  });
}
