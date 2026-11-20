import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/services/uuid.dart';

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

void main() {
  group('generateUuidV4', () {
    test('matches the 8-4-4-4-12 hex format', () {
      for (var i = 0; i < 100; i++) {
        expect(_uuidPattern.hasMatch(generateUuidV4()), isTrue, reason: 'iteration $i');
      }
    });

    test('version nibble is always 4', () {
      for (var i = 0; i < 100; i++) {
        final uuid = generateUuidV4();
        expect(uuid[14], '4');
      }
    });

    test('variant nibble is 8, 9, a or b', () {
      for (var i = 0; i < 100; i++) {
        final uuid = generateUuidV4();
        expect(const ['8', '9', 'a', 'b'], contains(uuid[19]));
      }
    });

    test('two calls differ', () {
      final seen = <String>{};
      for (var i = 0; i < 100; i++) {
        seen.add(generateUuidV4());
      }
      expect(seen.length, 100);
    });

    test('accepts an injectable random source', () {
      final uuid = generateUuidV4(Random(42));
      expect(_uuidPattern.hasMatch(uuid), isTrue);
      expect(generateUuidV4(Random(42)), uuid);
    });
  });
}
