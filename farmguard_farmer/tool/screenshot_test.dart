/// Golden-image harness that renders the real FarmGuard Farmer widget tree
/// with the same fake backend the widget tests use, and writes the README
/// screenshots as 1080×2400 PNGs into `tool/screenshots/`.
///
/// ```sh
/// flutter test tool/screenshot_test.dart --update-goldens   # (re)generate
/// flutter test tool/screenshot_test.dart                    # verify
/// ```
///
/// Each screenshot is its own `testWidgets` case, so a broken screen fails
/// only that capture instead of aborting the whole run.
///
/// ## Why the extra device frame plumbing
///
/// `matchesGoldenFile` rasterizes the nearest repaint boundary at
/// `pixelRatio: 1.0`, i.e. in *logical* pixels. A 360×800 dp phone viewport
/// would therefore produce a 360×800 PNG. To get a true 1080×2400 (3×)
/// screenshot the view is 1080×2400 logical px, while the app itself is laid
/// out at 360×800 dp with `devicePixelRatio: 3.0` (the real phone geometry)
/// and scaled up by a [FittedBox]. The scale happens inside the rasterizer,
/// so text and icons stay crisp vectors — this is a real 3× screenshot, not
/// an upscaled one.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:farmguard_farmer/main.dart';
import 'package:farmguard_farmer/models/models.dart';
import 'package:farmguard_farmer/services/api/farmer_api.dart';
import 'package:farmguard_farmer/services/app_services.dart';

import '../test/helpers/api_fixtures.dart';
import '../test/helpers/widget_pump.dart';

// ---------------------------------------------------------------------------
// Device geometry
// ---------------------------------------------------------------------------

/// Size of the produced PNG, in pixels.
const Size _pngSize = Size(1080, 2400);

/// Logical (dp) phone viewport the app is laid out at: 1080×2400 @ 3×.
const Size _screenSize = Size(360, 800);

/// Phone pixel density.
const double _devicePixelRatio = 3.0;

/// Simulated status-bar inset so the content is not glued to the top edge.
const double _statusBarInset = 24;

/// Root repaint boundary that every golden is captured from.
const Key _captureKey = ValueKey<String>('farmguard-screenshot-root');

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------

/// Flutter's bundled Material fonts. Widget tests otherwise fall back to the
/// test font (Ahem), which paints every glyph as a solid black box.
const String _fontDir =
    '/home/yash/flutter/bin/cache/artifacts/material_fonts';

/// The default text family plus its weights used by the app's type scale.
const Map<String, List<String>> _fontFiles = <String, List<String>>{
  'Roboto': <String>[
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ],
  'MaterialIcons': <String>['MaterialIcons-Regular.otf'],
};

/// Loads the real fonts into the test engine's font collection.
///
/// Custom families declared in `pubspec.yaml` (none today) would be added
/// here under their declared family name; the harness warns if one appears so
/// it can never silently fall back to boxes.
Future<void> _loadFonts() async {
  for (final MapEntry<String, List<String>> family in _fontFiles.entries) {
    final FontLoader loader = FontLoader(family.key);
    for (final String file in family.value) {
      loader.addFont(_readFont('$_fontDir/$file'));
    }
    await loader.load();
  }

  final String pubspec = File('pubspec.yaml').readAsStringSync();
  if (RegExp(r'^  fonts:', multiLine: true).hasMatch(pubspec)) {
    stdout.writeln(
      '[screenshot] WARNING: pubspec.yaml declares custom fonts — add them to '
      '_fontFiles or their text will render as boxes.',
    );
  }
}

Future<ByteData> _readFont(String path) async {
  final Uint8List bytes = File(path).readAsBytesSync();
  return ByteData.sublistView(bytes);
}

// ---------------------------------------------------------------------------
// Golden comparison with a small tolerance
// ---------------------------------------------------------------------------

/// Golden comparator that tolerates a tiny amount of pixel drift.
///
/// The app renders "live" relative timestamps ("34 min ago", "Today, 3:05 PM",
/// the pairing-code countdown), so a byte-exact golden would rot within
/// minutes. Everything structural — layout, fonts, colors, images — still has
/// to match: more than [_maxDiffPercent] of the pixels differing is a failure
/// and produces the usual `failures/` diff images.
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile, this._maxDiffPercent);

  final double _maxDiffPercent;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final ComparisonResult result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    final bool passed =
        result.passed || result.diffPercent <= _maxDiffPercent;
    if (passed) {
      result.dispose();
      return true;
    }
    final String error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

/// Max share of differing pixels allowed (0.5%). Time-of-day text churn is
/// well under this; a missing font, an overflow stripe or a blank frame is
/// orders of magnitude above it.
///
/// The demo dataset renders relative timestamps ("Today, 3:05 PM",
/// "34 min ago"), so once the clock rolls past midnight re-run with
/// `--update-goldens` to refresh the reference images.
const double _maxDiffPercent = 0.005;

void _installComparator() {
  final GoldenFileComparator previous = goldenFileComparator;
  final Uri testFile = previous is LocalFileComparator
      ? previous.basedir.resolve('screenshot_test.dart')
      : Uri.parse('tool/screenshot_test.dart');
  goldenFileComparator = _TolerantComparator(testFile, _maxDiffPercent);
}

// ---------------------------------------------------------------------------
// Harness plumbing
// ---------------------------------------------------------------------------

/// Sizes the test view to the 1080×2400 capture surface.
///
/// `matchesGoldenFile` rasterizes at `pixelRatio: 1.0` in *logical* pixels, so
/// the view has to be 1080×2400 logical px for the PNG to come out 1080×2400.
/// The 3× phone density the widgets themselves see comes from the
/// [MediaQuery] in [_deviceFrame], not from this view.
void _useDeviceFrame(WidgetTester tester) {
  tester.view.physicalSize = _pngSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Wraps the app in the simulated phone: a 1080×2400 capture surface, the
/// 360×800 dp / 3× media query the widgets read, and the 3× scale-up.
Widget _deviceFrame(Widget app) {
  return RepaintBoundary(
    key: _captureKey,
    child: MediaQuery(
      data: const MediaQueryData(
        size: _screenSize,
        devicePixelRatio: _devicePixelRatio,
        padding: EdgeInsets.only(top: _statusBarInset),
        // The dashboard's pulse dot loops forever; pinning animations off
        // keeps every capture deterministic.
        disableAnimations: true,
      ),
      child: FittedBox(
        child: SizedBox(
          width: _screenSize.width,
          height: _screenSize.height,
          child: app,
        ),
      ),
    ),
  );
}

/// A camera with a short, realistic location so the card reads well at the
/// 360 dp capture width (the shared `apiCamera` fixture reuses one long
/// location for every camera).
FarmCamera _camera({
  required String id,
  required String name,
  required String location,
  bool isOnline = true,
  Duration? lastSeen,
}) {
  return FarmCamera(
    id: id,
    name: name,
    location: location,
    isOnline: isOnline,
    isMonitoring: true,
    lastConnected:
        lastSeen == null ? null : DateTime.now().subtract(lastSeen),
  );
}

/// Boots the real app with fake-backed services — the same wiring as
/// `test/helpers/widget_pump.dart`, plus the device frame. [token] `null`
/// lands on the login screen; a saved token lands on the signed-in shell.
Future<void> _pumpFarmerApp(
  WidgetTester tester, {
  FakeFarmerApi? api,
  String? token = 'tok-123',
}) async {
  final RecordingTokenStore store = RecordingTokenStore();
  if (token != null) {
    await store.saveToken(token);
  }
  final AppServices services = AppServices(
    tokenStore: store,
    api: api ?? demoApi(),
  );
  await tester.pumpWidget(_deviceFrame(FarmGuardApp(services: services)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Lets asset images decode and paint before the capture. Asset decoding is
/// real async work, so it has to run outside the fake-async zone.
Future<void> _settleImages(WidgetTester tester) async {
  await tester.pump();
  final List<Element> images = find.byType(Image).evaluate().toList();
  if (images.isEmpty) return;
  await tester.runAsync(() async {
    for (final Element element in images) {
      final Image image = element.widget as Image;
      await precacheImage(
        image.image,
        element,
        onError: (Object error, StackTrace? stackTrace) {},
      );
    }
  });
  // The decoded frame reaches the Image widgets a frame or two after the
  // precache future completes (the detail screen's FutureBuilder rebuilds
  // once more), so paint a few frames before capturing.
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

/// Captures [name] and prints a clear PASS/FAIL line for the run log.
Future<void> _capture(WidgetTester tester, String name) async {
  await _settleImages(tester);
  final String golden = 'screenshots/$name.png';
  try {
    await expectLater(find.byKey(_captureKey), matchesGoldenFile(golden));
    final File file = File('tool/$golden');
    final String size = file.existsSync()
        ? ' (${(file.lengthSync() / 1024).toStringAsFixed(0)} KB)'
        : '';
    stdout.writeln('[screenshot] PASS  $golden$size');
  } catch (error) {
    stdout.writeln('[screenshot] FAIL  $golden — $error');
    rethrow;
  }
}

// ---------------------------------------------------------------------------
// Screens
// ---------------------------------------------------------------------------

void main() {
  setUpAll(_loadFonts);
  setUp(_installComparator);

  testWidgets('farmer-login.png — sign-in screen', (WidgetTester tester) async {
    _useDeviceFrame(tester);
    await _pumpFarmerApp(tester, token: null);
    await _capture(tester, 'farmer-login');
  });

  testWidgets('farmer-home.png — dashboard with demo alerts',
      (WidgetTester tester) async {
    _useDeviceFrame(tester);
    await _pumpFarmerApp(tester);
    await _capture(tester, 'farmer-home');
  });

  testWidgets('farmer-cameras.png — online, offline and remove actions',
      (WidgetTester tester) async {
    _useDeviceFrame(tester);
    await _pumpFarmerApp(
      tester,
      api: FakeFarmerApi(
        authResult: authResult(),
        cameras: <FarmCamera>[
          _camera(
            id: 'cam-main-gate',
            name: 'Main Gate',
            location: 'Farm entrance, north gate',
            lastSeen: const Duration(minutes: 2),
          ),
          _camera(
            id: 'cam-cow-shed',
            name: 'Cow Shed',
            location: 'Livestock area, east side',
            lastSeen: const Duration(minutes: 41),
          ),
          _camera(
            id: 'cam-pump-house',
            name: 'Pump House',
            location: 'Canal water pump station',
            isOnline: false,
            lastSeen: const Duration(hours: 26),
          ),
        ],
      ),
    );
    await tapNav(tester, 'Cameras');
    await _capture(tester, 'farmer-cameras');
  });

  testWidgets('farmer-history.png — detection history', (
    WidgetTester tester,
  ) async {
    _useDeviceFrame(tester);
    await _pumpFarmerApp(tester);
    await tapNav(tester, 'History');
    await _capture(tester, 'farmer-history');
  });

  testWidgets('farmer-alert-detail.png — detection detail with frame',
      (WidgetTester tester) async {
    _useDeviceFrame(tester);
    // A DEMO-source backend event: the DEMO chip comes from the backend's
    // `source_type` and the frame is a real captured photo, with one
    // detection bounding box so the detail screen shows its labelling.
    await _pumpFarmerApp(
      tester,
      api: FakeFarmerApi(
        authResult: authResult(),
        cameras: <FarmCamera>[
          _camera(
            id: 'cam-crop-field',
            name: 'North Crop Field',
            location: 'Irrigated field, north boundary',
            lastSeen: const Duration(minutes: 12),
          ),
        ],
        events: <ApiDetectionEvent>[
          apiEvent(
            id: 'evt-demo-1',
            cameraId: 'cam-crop-field',
            sourceType: 'DEMO',
            confidence: 0.96,
            boxes: const <ApiBoundingBox>[
              ApiBoundingBox(left: 0.38, top: 0.42, width: 0.28, height: 0.34),
            ],
          ),
        ],
        imageBytes: File(
          'assets/detections/detection_5.png',
        ).readAsBytesSync(),
      ),
    );
    await tapNav(tester, 'History');
    await tester.tap(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.text('Person detected'),
          )
          .first,
      warnIfMissed: false,
    );
    await settle(tester);
    await _capture(tester, 'farmer-alert-detail');
  });

  testWidgets('farmer-settings.png — settings tab', (WidgetTester tester) async {
    _useDeviceFrame(tester);
    await _pumpFarmerApp(tester);
    await tapNav(tester, 'Settings');
    await _capture(tester, 'farmer-settings');
  });

  testWidgets('farmer-pairing.png — pairing-code dialog',
      (WidgetTester tester) async {
    _useDeviceFrame(tester);
    await _pumpFarmerApp(
      tester,
      api: FakeFarmerApi(
        authResult: authResult(),
        cameras: <FarmCamera>[
          _camera(
            id: 'cam-main-gate',
            name: 'Main Gate',
            location: 'Farm entrance, north gate',
            lastSeen: const Duration(minutes: 2),
          ),
        ],
        pairingCode: PairingCodeResult(
          code: '428913',
          expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        ),
      ),
    );
    await tapNav(tester, 'Cameras');
    await tester.tap(find.widgetWithText(FilledButton, 'Pair a camera'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await _capture(tester, 'farmer-pairing');
    // Close the dialog so its countdown timer is cancelled before teardown.
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  });
}
