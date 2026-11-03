import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/cupertino.dart';
import 'package:throwcast/engine.dart';
import 'package:throwcast/main.dart';

class FakeEngine extends Engine {
  FakeEngine({required this.casting});
  final bool casting;

  @override
  void start() {
    tvs.add(Tv('1', 'Samsung AU8000 55 TV', 'UN55AU8000', '192.0.2.10', 3840, 2160));
    notifyListeners();
    if (!casting) return;
    state = CastState.casting;
    tabTitle = 'A very long episode title that keeps going and going';
    tabDuration = 3275;
    tabTime = 3112;
    tabVolume = 0.5;
    stats = const Stats(fps: 58, mbps: 7, rttMs: 240);
  }

  @override
  void send(Map<String, Object?> command) {}
}

void main() {
  setUp(() {
    SavedSettings.file = File('${Directory.systemTemp.createTempSync().path}/settings.json');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel('throwcast/commands'), (_) async => null)
      ..setMockStreamHandler(const EventChannel('throwcast/events'), null);
  });

  testWidgets('a new color profile is named, saved and survives a restart', (tester) async {
    tester.view.physicalSize = const Size(880, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> open() async {
      await tester.pumpWidget(CupertinoApp(key: UniqueKey(), home: HomePage(engine: FakeEngine(casting: false))));
      await tester.pump(const Duration(milliseconds: 100));
    }

    await open();
    await tester.tap(find.text('New'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(CupertinoTextField), 'Late Night');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(SavedSettings.load()['profile'], startsWith('custom-'));

    await open();
    expect(find.text('Late Night'), findsOneWidget);
    expect(find.text('Delete Profile'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  // Large text is how many people read, so it has to hold together in every shape of the window.
  for (final (size, scale) in const [(Size(880, 2400), 1.0), (Size(880, 2400), 1.5), (Size(380, 2400), 1.0), (Size(380, 2400), 1.5)]) {
    for (final casting in [false, true]) {
      testWidgets('lays out at $size, text $scale, casting $casting', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
          child: CupertinoApp(home: HomePage(engine: FakeEngine(casting: casting))),
        ));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Adjust Picture'));
        await tester.tap(find.text('More Options'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
