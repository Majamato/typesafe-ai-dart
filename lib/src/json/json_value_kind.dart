/// A JSON value shape, naming both what a reader expected and what it found.
/// Each value's [label] is the word that appears in error messages.
enum JsonValueKind {
  nullValue('null'),
  boolean('boolean'),
  string('string'),
  integer('integer'),
  decimal('double'),
  number('number'),
  array('array'),
  object('object');

  const JsonValueKind(this.label);

  /// How this kind is spelled in an error message.
  final String label;

  /// The kind of [value] as `jsonDecode` produced it, or `null` for anything
  /// outside the JSON data model.
  static JsonValueKind? of(Object? value) => switch (value) {
    null => nullValue,
    bool() => boolean,
    String() => string,
    int() => integer,
    double() => decimal,
    List<Object?>() => array,
    Map<String, Object?>() => object,
    _ => null,
  };
}
