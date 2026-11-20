import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmguard_farmer/screens/detection_detail_screen.dart';

import 'helpers/widget_pump.dart';

/// The original widget tests. DATA SOURCE: they run on the demo dataset —
/// [pumpApp] wires a fake backend mirroring the old MockData world (no live
/// events; 4 cameras, 3 online), so the asserted strings below ('3 / 4',
/// 'Main Gate', 'Offline', 'New') are the same demo-data contract as before
/// Stage 6.
///
/// The Home tab has a repeating pulse animation, so tests use fixed pumps
/// instead of pumpAndSettle.
///
/// Navigation needs two pumps: one to flush the build, one to advance the
/// route/tab transition.

void main() {
  testWidgets('Home dashboard renders key metrics', (WidgetTester tester) async {
    await pumpApp(tester);

    expect(find.text('Farmer'), findsOneWidget);
    expect(find.text('Detections today'), findsOneWidget);
    expect(find.text('Connected cameras'), findsOneWidget);
    expect(find.text('Attention needed'), findsOneWidget);
    expect(find.text('3 / 4'), findsOneWidget);
    expect(find.text('Recent detections'), findsOneWidget);
    expect(find.text('View all'), findsOneWidget);
  });

  testWidgets('Bottom navigation switches tabs', (WidgetTester tester) async {
    await pumpApp(tester);

    await tapNav(tester, 'History');
    expect(find.text('Detection history'), findsOneWidget);

    await tapNav(tester, 'Cameras');
    expect(find.text('Main Gate'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);

    await tapNav(tester, 'Settings');
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Person detection alerts'), findsOneWidget);

    // App information sits below the fold; scroll to reach it.
    await tester.drag(find.text('Notifications'), const Offset(0, -400));
    await settle(tester);
    expect(find.text('Version'), findsOneWidget);
  });

  testWidgets('History opens detection details', (WidgetTester tester) async {
    await pumpApp(tester);

    await tapNav(tester, 'History');
    expect(find.text('New'), findsWidgets);

    // Scope to the History screen's list: the offstage Home tab also holds
    // "Person detected" tiles inside the IndexedStack.
    final titleInList = find.descendant(
      of: find.byType(ListView),
      matching: find.text('Person detected'),
    );
    await tester.tap(titleInList.first, warnIfMissed: false);
    await settle(tester);

    expect(find.text('Detection details'), findsOneWidget);
    expect(find.text('Person detected'), findsWidgets);

    // The captured frame fills most of the screen; scroll to the facts card.
    final imageInDetail = find.descendant(
      of: find.byType(DetectionDetailScreen),
      matching: find.byType(Image),
    );
    await tester.drag(imageInDetail.first, const Offset(0, -500), warnIfMissed: false);
    await settle(tester);

    expect(find.text('Confidence'), findsOneWidget);
    expect(find.text('Event ID'), findsOneWidget);
    expect(find.text('Location'), findsOneWidget);

    await tester.pageBack();
    await settle(tester);
    expect(find.text('Detection history'), findsOneWidget);
  });
}
