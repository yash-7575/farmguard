import 'package:flutter_test/flutter_test.dart';

import 'package:farmguard_farmer/services/api/token_store.dart';

void main() {
  group('InMemoryTokenStore', () {
    test('starts empty, saves, reads and clears', () async {
      final store = InMemoryTokenStore();

      expect(await store.readToken(), isNull);

      await store.saveToken('tok-1');
      expect(await store.readToken(), 'tok-1');

      // Saving again replaces the token.
      await store.saveToken('tok-2');
      expect(await store.readToken(), 'tok-2');

      await store.clear();
      expect(await store.readToken(), isNull);
    });
  });
}
