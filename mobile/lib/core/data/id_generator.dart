import 'dart:math';

/// Six-character record ids, e.g. "4K9X2M".
///
/// Short enough to read aloud across a counter, write on a claim tag, and
/// type back in — which the UUIDs this replaced never were. The alphabet
/// leaves out 0/O and 1/I so a handwritten id is never ambiguous, which
/// still leaves 32^6 (about a billion) combinations.
class IdGenerator {
  static const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  static const length = 6;

  final Random _random;

  IdGenerator({Random? random}) : _random = random ?? Random();

  String _raw() {
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(alphabet[_random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }

  /// A fresh id that isn't already taken. [isTaken] is checked against every
  /// record sharing the id space, so a purchase and a sale can never collide
  /// on the same code.
  String next(bool Function(String id) isTaken) {
    // Practically always succeeds first try; the bound just stops a pathological
    // loop if the id space were ever exhausted.
    for (var attempt = 0; attempt < 1000; attempt++) {
      final candidate = _raw();
      if (!isTaken(candidate)) return candidate;
    }
    throw StateError('Could not allocate an unused record id');
  }
}
