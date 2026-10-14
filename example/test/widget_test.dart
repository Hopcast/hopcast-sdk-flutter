// Basic smoke test for the Hopcast demo home page.
//
// Platform channels are not available under `flutter test`, so we build the
// HomePage with a fresh controller (without calling init()/plugins) and verify
// it renders its initial loading state.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hopcast_flutter_example/main.dart';
import 'package:hopcast_flutter_example/src/home_page.dart';

void main() {
  testWidgets('HomePage shows a loading indicator before the SDK is ready',
      (tester) async {
    final controller = HopcastController(() => tester.element(find.byType(Scaffold)));
    await tester.pumpWidget(
      MaterialApp(home: HomePage(controller: controller)),
    );
    await tester.pump();

    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
