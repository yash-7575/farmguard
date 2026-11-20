// Unit tests for the production CloudServices bundle.
//
// The production factory is safe to construct in tests: it only builds
// objects (no platform channel is touched) and is inert because the test
// runner sets FLUTTER_TEST. These tests guard the Phase 2B fix: the
// production bundle must create its own HttpFarmGuardApi with the token
// provider wired to the current registration.

import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/services/api_client.dart';
import 'package:farmguard_camera/services/cloud_services.dart';
import 'package:farmguard_camera/services/device_registration.dart';

void main() {
  group('CloudServices.production', () {
    test('creates an HttpFarmGuardApi that is also the upload client', () {
      final bundle = CloudServices.production();
      addTearDown(bundle.dispose);

      expect(bundle.api, isA<HttpFarmGuardApi>());
      expect(bundle.uploadClient, same(bundle.api));
      expect(bundle.backgroundEnabled, isFalse);
    });

    test('updateRegistration wires the camera token into the API provider', () {
      final bundle = CloudServices.production();
      addTearDown(bundle.dispose);

      final api = bundle.api as HttpFarmGuardApi;
      expect(bundle.currentToken, isNull);
      // No token yet: authenticated calls must not carry an Authorization
      // header.
      expect(api.tokenProvider, isNotNull);
      expect(api.tokenProvider!(), isNull);

      const registration = CameraRegistration(
        token: 'camera-token-123',
        cameraId: 'cam-1',
        cameraName: 'Field Camera 1',
      );
      bundle.updateRegistration(registration);

      expect(bundle.currentToken, 'camera-token-123');
      expect(api.tokenProvider!(), 'camera-token-123');

      bundle.updateRegistration(null);
      expect(bundle.currentToken, isNull);
      expect(api.tokenProvider!(), isNull);
    });

    test('injected api still wins over the default construction', () {
      final injected = HttpFarmGuardApi();
      addTearDown(injected.close);
      final bundle = CloudServices(api: injected);
      addTearDown(bundle.dispose);

      expect(bundle.api, same(injected));
      expect(bundle.uploadClient, same(injected));
    });
  });
}
