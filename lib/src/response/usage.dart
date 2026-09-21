import 'package:meta/meta.dart';

/// Token accounting for one API call. Counts are 0 whenever the API didn't
/// report them, so zero means "unreported", not "nothing consumed".
@immutable
final class Usage {
  const Usage({required this.inputTokens, required this.outputTokens});

  factory Usage.fromJson(Map<String, Object?> json) {
    final input = json['input_tokens'];
    final output = json['output_tokens'];
    return Usage(inputTokens: _count(input), outputTokens: _count(output));
  }

  /// Reads a token count, treating anything but a finite number as 0.
  static int _count(Object? value) =>
      value is num && value.isFinite ? value.toInt() : 0;

  /// The number of tokens the request's state and questions came to, from
  /// `input_tokens`.
  final int inputTokens;

  /// The number of tokens the model produced, from `output_tokens`.
  final int outputTokens;

  /// The sum of [inputTokens] and [outputTokens].
  int get totalTokens => inputTokens + outputTokens;

  /// Returns this record in the API's JSON shape.
  Map<String, Object?> toJson() => {
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
  };

  @override
  bool operator ==(Object other) =>
      other is Usage &&
      other.inputTokens == inputTokens &&
      other.outputTokens == outputTokens;

  @override
  int get hashCode => Object.hash(inputTokens, outputTokens);

  @override
  String toString() =>
      'Usage(inputTokens: $inputTokens, outputTokens: $outputTokens)';
}
