import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throwcast/widgets.dart';

void main() {
  testWidgets('a tap lands where it was pressed, away from the thumb', (tester) async {
    final values = <double>[];
    final ends = <double>[];
    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child: SizedBox(
          width: 244,
          child: TapSlider(value: 0, max: 10, onChanged: values.add, onChangeEnd: ends.add),
        ),
      ),
    ));
    final slider = tester.getRect(find.byType(TapSlider));
    await tester.tapAt(Offset(slider.left + 22 + 150, slider.center.dy));
    expect(values.single, closeTo(7.5, 0.01));
    expect(ends.single, closeTo(7.5, 0.01));
  });

  testWidgets('Tab reaches buttons and sliders; Space presses, arrows move', (tester) async {
    var pressed = 0;
    final values = <double>[];
    await tester.pumpWidget(CupertinoApp(
      home: Column(
        children: [
          SmallButton('Go', onTap: () => pressed++),
          SizedBox(width: 244, child: TapSlider(value: 5, max: 10, onChanged: values.add)),
        ],
      ),
    ));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(pressed, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(values, [5.5, 4.5]);
  });
}
