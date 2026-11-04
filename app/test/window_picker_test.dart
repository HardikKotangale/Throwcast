import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throwcast/engine.dart';
import 'package:throwcast/main.dart';

void main() {
  testWidgets('every window is listed, and a hidden one says why it has no picture', (tester) async {
    final windows = [
      for (var i = 0; i < 20; i++) WindowInfo(i, 'Google Chrome', 'Window $i', null, null, 1.6, hidden: i == 19),
    ];
    await tester.pumpWidget(CupertinoApp(
      home: SingleChildScrollView(
        child: SizedBox(
          width: 700,
          child: WindowPicker(windows: windows, loaded: true, selected: null, onSelected: (_) {}),
        ),
      ),
    ));
    expect(find.byType(WindowTile), findsNWidgets(20));
    expect(find.text('Minimized or on another desktop.\nBring it here to cast.'), findsOneWidget);
  });

  testWidgets('a hidden window with a picture shows it, with a label', (tester) async {
    // A 1x1 PNG stands in for the window's last picture.
    final png = Uint8List.fromList(const [
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 15, 4, 0, 9, 251, 3, 253, 227, 85, 242, 156, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    ]);
    await tester.pumpWidget(CupertinoApp(
      home: SizedBox(
        width: 700,
        child: WindowPicker(windows: [WindowInfo(1, 'Slack', 'General', png, null, 1.6, hidden: true)], loaded: true, selected: null, onSelected: (_) {}),
      ),
    ));
    expect(find.bySemanticsLabel('General preview'), findsOneWidget);
    expect(find.text('Hidden · bring it here to cast'), findsOneWidget);
  });
}
