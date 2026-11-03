import 'package:flutter/cupertino.dart';
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
}
