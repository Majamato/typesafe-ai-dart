/// Structural equality for decoded JSON values that walks with an explicit
/// stack, so a hostile nesting depth can't overflow the call stack.
library;

/// Whether [a] and [b] hold the same JSON: maps compare unordered by key,
/// lists in order, and everything else by `==`.
bool jsonEquals(Object? a, Object? b) {
  final pending = <(Object?, Object?)>[(a, b)];
  while (pending.isNotEmpty) {
    final (x, y) = pending.removeLast();
    if (identical(x, y)) {
      continue;
    }
    switch ((x, y)) {
      case (final Map<Object?, Object?> m, final Map<Object?, Object?> n):
        if (m.length != n.length) {
          return false;
        }
        for (final MapEntry(:key, :value) in m.entries) {
          if (!n.containsKey(key)) {
            return false;
          }
          pending.add((value, n[key]));
        }
      case (final List<Object?> l, final List<Object?> k):
        if (l.length != k.length) {
          return false;
        }
        for (var i = 0; i < l.length; i++) {
          pending.add((l[i], k[i]));
        }
      case (Map<Object?, Object?>() || List<Object?>(), _) ||
          (_, Map<Object?, Object?>() || List<Object?>()):
        return false;
      default:
        if (x != y) {
          return false;
        }
    }
  }
  return true;
}

/// A hash consistent with [jsonEquals] that looks one level deep only: a
/// map contributes its keys and a list its length.
int jsonHash(Object? value) => switch (value) {
  final Map<Object?, Object?> map => Object.hashAllUnordered(map.keys),
  final List<Object?> list => list.length,
  _ => value.hashCode,
};
