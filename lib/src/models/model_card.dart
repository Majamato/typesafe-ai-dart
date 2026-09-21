import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/json/json_fields.dart';

/// One model the account may use, as listed by `GET /v1/models`. Only [name]
/// is meaningful to the API; the rest are empty strings, not `null`, if unset.
@immutable
final class ModelCard {
  const ModelCard({
    required this.name,
    required this.description,
    required this.releaseDate,
  });

  factory ModelCard.fromJson(Map<String, Object?> json) => ModelCard(
    name: readString(json, 'name'),
    description: readOptionalString(json, 'description') ?? '',
    releaseDate: readOptionalString(json, 'release_date') ?? '',
  );

  /// The identifier to pass as `model` in a request, such as `jev-1.13.0`.
  final String name;

  /// Human readable summary of the model, empty when the API omitted it.
  final String description;

  /// Release date as the API reported it, normally `YYYY-MM-DD`, or empty
  /// when it omitted the field. Not parsed or validated.
  final String releaseDate;

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'release_date': releaseDate,
  };

  @override
  bool operator ==(Object other) =>
      other is ModelCard &&
      other.name == name &&
      other.description == description &&
      other.releaseDate == releaseDate;

  @override
  int get hashCode => Object.hash(name, description, releaseDate);

  @override
  String toString() => 'ModelCard(name: $name, releaseDate: $releaseDate)';
}
