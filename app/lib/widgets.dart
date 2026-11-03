import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

/// Apple's two spring parameters. Damping 1 settles without overshoot, which suits anything
/// that wasn't thrown by the user; response is roughly how long it takes to get there.
SpringDescription spring({double response = 0.35, double damping = 1}) {
  final stiffness = math.pow(2 * math.pi / response, 2).toDouble();
  return SpringDescription(mass: 1, stiffness: stiffness, damping: 2 * damping * math.sqrt(stiffness));
}

/// Rebuilds with a spring toward `value`. A new target starts from the value and velocity
/// on screen right now, so every change can be interrupted without a jump.
class Spring extends StatefulWidget {
  const Spring({required this.value, required this.builder, this.response = 0.35, this.child, super.key});
  final double value, response;
  final Widget Function(BuildContext context, double value, Widget? child) builder;
  final Widget? child;

  @override
  State<Spring> createState() => _SpringState();
}

class _SpringState extends State<Spring> with SingleTickerProviderStateMixin {
  late final controller = AnimationController.unbounded(vsync: this, value: widget.value);

  @override
  void didUpdateWidget(Spring old) {
    super.didUpdateWidget(old);
    if (old.value == widget.value) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.value = widget.value;
    } else {
      controller.animateWith(SpringSimulation(spring(response: widget.response), controller.value, widget.value, controller.velocity));
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: controller, child: widget.child, builder: (context, child) => widget.builder(context, controller.value, child));
}

/// Enter and Space press whatever has keyboard focus. Declared on each control, so they win over
/// the window's own Enter shortcut (start/stop casting) while a control is focused.
const pressKeys = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
};

/// The ring a keyboard-focused control wears, in the control's own shape.
Decoration focusRing(BuildContext context, {bool circle = false, double radius = 9}) {
  final side = BorderSide(color: accent.resolveFrom(context), width: 2);
  return ShapeDecoration(shape: circle ? CircleBorder(side: side) : RoundedRectangleBorder(side: side, borderRadius: BorderRadius.circular(radius)));
}

/// Dips the moment the pointer goes down and springs back on release. Tab reaches it, and
/// Enter or Space presses it, with a focus ring only while the keyboard is in use.
class Press extends StatefulWidget {
  const Press({
    required this.child,
    required this.onTap,
    this.label,
    this.selected = false,
    this.expanded,
    this.scale = 0.97,
    this.circle = false,
    this.focusNode,
    super.key,
  });
  final Widget child;
  final VoidCallback? onTap;
  final String? label;
  final bool selected;

  /// For controls that open and close something, so VoiceOver says "expanded" rather than "selected".
  final bool? expanded;
  final double scale;
  final bool circle;
  final FocusNode? focusNode;

  @override
  State<Press> createState() => _PressState();
}

class _PressState extends State<Press> {
  var pressed = false;
  var ring = false;

  void set(bool value) {
    if (widget.onTap != null) setState(() => pressed = value);
  }

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: widget.onTap != null,
        selected: widget.expanded == null ? widget.selected : null,
        expanded: widget.expanded,
        label: widget.label,
        child: FocusableActionDetector(
          focusNode: widget.focusNode,
          enabled: widget.onTap != null,
          mouseCursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
          shortcuts: pressKeys,
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap?.call())},
          onShowFocusHighlight: (value) => setState(() => ring = value),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => set(true),
            onTapCancel: () => set(false),
            onTapUp: (_) => set(false),
            onTap: widget.onTap,
            child: Spring(
              value: pressed ? widget.scale : 1,
              response: 0.22,
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: ring ? focusRing(context, circle: widget.circle) : const BoxDecoration(),
                child: widget.child,
              ),
              builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
            ),
          ),
        ),
      );
}

const accent = CupertinoColors.activeBlue;

extension Palette on BuildContext {
  bool get isDark => CupertinoTheme.brightnessOf(this) == Brightness.dark;
  Color get label => CupertinoColors.label.resolveFrom(this);
  Color get secondary => CupertinoColors.secondaryLabel.resolveFrom(this);
  Color get line => CupertinoColors.separator.resolveFrom(this);

  /// A solid-feeling fill over the window material. Never a second translucent blur.
  Color get surface => isDark ? const Color(0x14FFFFFF) : const Color(0xB3FFFFFF);

  /// The settings pane: more solid than the window material, so the TV side reads as the lighter layer.
  Color get pane => isDark ? const Color(0x731C1C1E) : const Color(0x80F5F5F7);
  Border? get contrastBorder => MediaQuery.highContrastOf(this) ? Border.all(color: secondary) : null;
}

class Group extends StatelessWidget {
  const Group({required this.children, super.key});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: context.surface, borderRadius: BorderRadius.circular(12), border: context.contrastBorder),
        child: Column(
          children: [
            for (final (index, child) in children.indexed) ...[
              if (index > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: SizedBox(height: 0.5, width: double.infinity, child: ColoredBox(color: context.line)),
                ),
              child,
            ],
          ],
        ),
      );
}

/// CupertinoSlider only answers near its thumb. This one jumps to wherever it's pressed, on the
/// press itself, then follows the pointer until release. Tab reaches it; Left and Right move it
/// a twentieth of its range, held keys repeating.
class TapSlider extends StatelessWidget {
  const TapSlider({required this.value, required this.onChanged, this.onChangeEnd, this.min = 0, this.max = 1, super.key});
  final double value, min, max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  // CupertinoSlider's own inset: its padding of 8 plus the thumb's radius of 14.
  static const inset = 22.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          double at(PointerEvent event) {
            final travel = math.max(box.maxWidth - inset * 2, 1);
            return min + ((event.localPosition.dx - inset) / travel).clamp(0.0, 1.0) * (max - min);
          }

          KeyEventResult key(FocusNode _, KeyEvent event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            final step = event.logicalKey == LogicalKeyboardKey.arrowRight
                ? 1
                : event.logicalKey == LogicalKeyboardKey.arrowLeft
                    ? -1
                    : 0;
            if (step == 0) return KeyEventResult.ignored;
            final next = (value + step * (max - min) / 20).clamp(min, max);
            onChanged(next);
            onChangeEnd?.call(next);
            return KeyEventResult.handled;
          }

          return Focus(
            onKeyEvent: key,
            child: Builder(
              builder: (context) {
                final ring = Focus.of(context).hasPrimaryFocus && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) => onChanged(at(event)),
                    onPointerMove: (event) => onChanged(at(event)),
                    onPointerUp: (event) => onChangeEnd?.call(at(event)),
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: ring ? focusRing(context, radius: 16) : const BoxDecoration(),
                      child: SizedBox(
                        width: double.infinity,
                        child: IgnorePointer(child: CupertinoSlider(value: value, min: min, max: max, onChanged: onChanged)),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      );
}

/// A sun that wakes up with the slider, following it 1:1: rays grow out one after another,
/// the center swells and warms, and a glow arrives at the top of the range.
class SunGlyph extends StatelessWidget {
  const SunGlyph(this.level, {super.key});

  /// From 0, darkest, to 1, brightest.
  final double level;

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size.square(34), painter: _SunPainter(level.clamp(0.0, 1.0), context.secondary));
}

class _SunPainter extends CustomPainter {
  _SunPainter(this.level, this.dim);
  final double level;
  final Color dim;

  static const rays = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final color = Color.lerp(dim, const Color(0xFFFFC800), Curves.easeOut.transform(level))!;
    final core = 4.0 + 2.5 * level;
    final glow = ((level - 0.6) / 0.4).clamp(0.0, 1.0);
    if (glow > 0) {
      canvas.drawCircle(center, core + 7, Paint()
        ..color = const Color(0xFFFFC800).withValues(alpha: 0.4 * glow)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    }
    canvas.drawCircle(center, core, Paint()..color = color);
    final ray = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    for (var index = 0; index < rays; index++) {
      // Each ray takes its turn, so moving the slider a little always changes something.
      final grown = ((level * rays * 0.72 - index * 0.5)).clamp(0.0, 1.0);
      if (grown == 0) continue;
      final direction = Offset.fromDirection(index * 3 * 2 * math.pi / rays - math.pi / 2);
      final start = core + 2.5;
      canvas.drawLine(center + direction * start, center + direction * (start + 1 + 3.5 * grown), ray);
    }
  }

  @override
  bool shouldRepaint(_SunPainter old) => old.level != level || old.dim != dim;
}

/// What each picture slider changes. The glyph is a tiny picture of that change, not a symbol for it.
enum Tone { contrast, color, warmth, shadows }

class ToneGlyph extends StatelessWidget {
  const ToneGlyph(this.tone, this.level, {super.key});
  final Tone tone;

  /// From 0, the left end of the slider, to 1, the right end.
  final double level;

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size.square(34), painter: _TonePainter(tone, level.clamp(0.0, 1.0), context.line));
}

class _TonePainter extends CustomPainter {
  _TonePainter(this.tone, this.level, this.outline);
  final Tone tone;
  final double level;
  final Color outline;

  static const white = Color(0xFFFFFFFF), gray = Color(0xFF808080), black = Color(0xFF000000);

  Paint get edge => Paint()
    ..color = outline
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    switch (tone) {
      // Two halves start the same gray and pull apart into black and white.
      case Tone.contrast:
        final disc = Rect.fromCircle(center: center, radius: 10);
        canvas.drawArc(disc, math.pi / 2, math.pi, true, Paint()..color = Color.lerp(gray, black, level)!);
        canvas.drawArc(disc, -math.pi / 2, math.pi, true, Paint()..color = Color.lerp(gray, white, level)!);
        canvas.drawCircle(center, 10, edge);
      // Gray dots fill with color as they spread apart.
      case Tone.color:
        const colors = [Color(0xFFFF3B30), Color(0xFF34C759), Color(0xFF0A84FF)];
        for (final (index, color) in colors.indexed) {
          final spot = center + Offset.fromDirection(index * 2 * math.pi / 3 - math.pi / 2, 4 + 1.5 * level);
          canvas.drawCircle(spot, 6.5, Paint()..color = Color.lerp(const Color(0xFF8E8E93), color, level)!.withValues(alpha: 0.9));
        }
      // Blue, through white, to orange: the actual colors the picture leans toward.
      case Tone.warmth:
        const cool = Color(0xFF3F9BFF), warm = Color(0xFFFF8A1F), plain = Color(0xFFF4F1EA);
        final color = level < 0.5 ? Color.lerp(cool, plain, level * 2)! : Color.lerp(plain, warm, level * 2 - 1)!;
        final strength = (level - 0.5).abs() * 2;
        if (strength > 0) {
          canvas.drawCircle(center, 13, Paint()
            ..color = color.withValues(alpha: 0.4 * strength)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
        }
        canvas.drawCircle(center, 9.5, Paint()..color = color);
      // Three steps of a gray scale. The dark two lift while white stays put.
      case Tone.shadows:
        final steps = [Color.lerp(black, const Color(0xFF5A5A5A), level)!, Color.lerp(const Color(0xFF3A3A3A), const Color(0xFFB0B0B0), level)!, white];
        final strip = RRect.fromRectAndRadius(Rect.fromCenter(center: center, width: 26, height: 16), const Radius.circular(4));
        canvas.save();
        canvas.clipRRect(strip);
        for (final (index, color) in steps.indexed) {
          canvas.drawRect(Rect.fromLTWH(strip.left + index * 26 / 3, strip.top, 26 / 3 + 0.5, 16), Paint()..color = color);
        }
        canvas.restore();
        canvas.drawRRect(strip, edge);
    }
  }

  @override
  bool shouldRepaint(_TonePainter old) => old.level != level || old.tone != tone || old.outline != outline;
}

/// A small square of color that marks a row, so settings can be found by sight before reading.
class IconBadge extends StatelessWidget {
  const IconBadge(this.icon, this.color, {super.key});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
        child: Icon(icon, size: 16, color: CupertinoColors.white),
      );
}

/// Tracks the pointer 1:1, with a light magnet at the neutral point so it's easy to get back to.
/// The icon shows the effect as it changes, and pressing it goes back to neutral.
class SliderRow extends StatelessWidget {
  const SliderRow({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.neutral,
    required this.glyph,
    required this.onChanged,
    super.key,
  });
  final String title;
  final double value, min, max, neutral;
  final ValueChanged<double> onChanged;

  /// Shows the effect itself, given how far the slider sits from neutral, from -1 to 1.
  final Widget Function(double shift) glyph;

  double get shift => value >= neutral ? (value - neutral) / (max - neutral) : (value - neutral) / (neutral - min);

  String get readout {
    final percent = (shift * 100).round();
    return percent == 0 ? '0' : (percent > 0 ? '+$percent' : '$percent');
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: title,
        value: readout,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 3, 14, 3),
          child: Row(
            children: [
              Press(
                scale: 0.88,
                circle: true,
                label: 'Reset $title',
                onTap: () => onChanged(neutral),
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: glyph(shift),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(width: 78, child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
              Expanded(
                child: TapSlider(
                  value: value.clamp(min, max),
                  min: min,
                  max: max,
                  onChanged: (next) => onChanged((next - neutral).abs() < (max - min) * 0.02 ? neutral : next),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(readout, textAlign: TextAlign.right, style: TextStyle(color: context.secondary, fontFeatures: const [FontFeature.tabularFigures()])),
              ),
            ],
          ),
        ),
      );
}

class SwitchRow extends StatelessWidget {
  const SwitchRow({required this.title, required this.value, required this.onChanged, this.badge, super.key});
  final String title;
  final Widget? badge;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
        child: Row(
          children: [
            if (badge != null) ...[badge!, const SizedBox(width: 11)],
            Expanded(child: Text(title)),
            Transform.scale(scale: 0.72, child: CupertinoSwitch(value: value, onChanged: onChanged)),
          ],
        ),
      );
}

class SmallButton extends StatelessWidget {
  const SmallButton(this.text, {required this.onTap, this.primary = false, this.icon, super.key});

  /// Also the button's spoken label when `icon` replaces it on screen.
  final String text;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Press(
        onTap: onTap,
        label: text,
        child: Opacity(
          opacity: onTap == null ? 0.45 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(color: primary ? accent.resolveFrom(context) : context.surface, borderRadius: BorderRadius.circular(7)),
            alignment: icon == null ? null : Alignment.center,
            child: icon != null
                ? Icon(icon, size: 18, color: primary ? CupertinoColors.white : context.label)
                : Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: primary ? CupertinoColors.white : context.label)),
          ),
        ),
      );
}

/// A round control with room for any finger or pointer. Size follows importance.
class CircleButton extends StatelessWidget {
  const CircleButton({required this.icon, required this.label, required this.onTap, this.size = 44, this.primary = false, super.key});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;
  final bool primary;

  @override
  Widget build(BuildContext context) => Press(
        onTap: onTap,
        label: label,
        scale: 0.94,
        circle: true,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: primary ? accent.resolveFrom(context) : context.surface, shape: BoxShape.circle, border: context.contrastBorder),
          child: Icon(icon, size: size * 0.5, color: primary ? CupertinoColors.white : context.label),
        ),
      );
}

/// Controls that belong together, on one quiet surface.
class Panel extends StatelessWidget {
  const Panel({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: context.surface, borderRadius: BorderRadius.circular(14), border: context.contrastBorder),
        child: child,
      );
}

/// A title that opens more detail. The chevron turns, so it's clear which way it went.
class Disclosure extends StatelessWidget {
  const Disclosure({required this.title, required this.open, required this.onTap, super.key});
  final String title;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Press(
        scale: 0.99,
        label: title,
        expanded: open,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          child: Row(
            children: [
              Spring(
                value: open ? 0.25 : 0,
                builder: (_, turns, child) => Transform.rotate(angle: turns * 2 * math.pi, child: child),
                child: Icon(CupertinoIcons.chevron_right, size: 13, color: context.secondary),
              ),
              const SizedBox(width: 8),
              Flexible(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            ],
          ),
        ),
      );
}

/// Opens and closes with its neighbors moving aside, instead of a jump.
class Reveal extends StatelessWidget {
  const Reveal({required this.open, required this.child, super.key});
  final bool open;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220),
        curve: const Cubic(0.23, 1, 0.32, 1),
        alignment: Alignment.topCenter,
        child: open ? child : const SizedBox(width: double.infinity),
      );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {this.badge, super.key});
  final String text;
  final Widget? badge;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 7),
        child: Row(
          children: [
            if (badge != null) ...[badge!, const SizedBox(width: 9)],
            Flexible(child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.1))),
          ],
        ),
      );
}

class Caption extends StatelessWidget {
  const Caption(this.text, {this.align, super.key});
  final String text;
  final TextAlign? align;

  @override
  Widget build(BuildContext context) =>
      Text(text, textAlign: align, style: TextStyle(fontSize: 13, height: 1.35, color: context.secondary));
}

/// macOS-style segmented control. The thumb slides on a spring, so quick clicks redirect it mid-flight.
class Segments<T> extends StatelessWidget {
  const Segments({required this.value, required this.options, required this.onChanged, super.key});
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final keys = options.keys.toList();
    return Container(
      height: 38,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: context.surface, borderRadius: BorderRadius.circular(9), border: context.contrastBorder),
      child: LayoutBuilder(
        builder: (context, box) {
          final width = box.maxWidth / keys.length;
          return Stack(
            children: [
              Spring(
                value: keys.indexOf(value).toDouble(),
                builder: (_, index, child) => Positioned(left: index * width, top: 0, bottom: 0, width: width, child: child!),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.isDark ? const Color(0x33FFFFFF) : CupertinoColors.white,
                    borderRadius: BorderRadius.circular(7),
                    boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 3, offset: Offset(0, 1))],
                  ),
                ),
              ),
              Row(
                children: [
                  for (final key in keys)
                    Expanded(
                      child: Press(
                        scale: 0.95,
                        selected: key == value,
                        label: options[key],
                        onTap: () => onChanged(key),
                        child: Center(
                          child: Text(options[key]!, style: TextStyle(fontSize: 14, fontWeight: key == value ? FontWeight.w600 : FontWeight.w400)),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A row that opens a menu growing out of the value that was clicked.
class MenuRow<T> extends StatefulWidget {
  const MenuRow({required this.title, required this.value, required this.options, required this.onChanged, this.badge, this.note, super.key});
  final String title;
  final Widget? badge;

  /// A line under the title, for what the current choice means.
  final String? note;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  State<MenuRow<T>> createState() => _MenuRowState<T>();
}

class _MenuRowState<T> extends State<MenuRow<T>> {
  final anchor = LayerLink();
  final portal = OverlayPortalController();
  final rowFocus = FocusNode();
  var opensUp = false;
  var room = 300.0;

  @override
  void dispose() {
    rowFocus.dispose();
    super.dispose();
  }

  /// Keyboard focus goes back to the row, so Tab carries on from where the menu was opened.
  void close() {
    portal.hide();
    rowFocus.requestFocus();
  }

  /// Opens toward whichever side has room, so the menu never runs off the window.
  void toggle() {
    if (portal.isShowing) return close();
    final box = context.findRenderObject()! as RenderBox;
    final top = box.localToGlobal(Offset.zero).dy;
    final height = MediaQuery.sizeOf(context).height;
    final below = height - top - box.size.height - 14;
    final above = top - 36;
    final wanted = widget.options.length * 30.0 + 12;
    setState(() {
      opensUp = below < wanted && above > below;
      room = opensUp ? above : below;
    });
    portal.show();
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
        link: anchor,
        child: OverlayPortal(
          controller: portal,
          overlayChildBuilder: (_) => _menu(context),
          child: Press(
            scale: 0.99,
            focusNode: rowFocus,
            onTap: toggle,
            label: '${widget.title}, ${widget.options[widget.value]}',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  if (widget.badge != null) ...[widget.badge!, const SizedBox(width: 11)],
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title),
                        if (widget.note != null) Caption(widget.note!),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: Text(widget.options[widget.value] ?? '', textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.secondary)),
                  ),
                  const SizedBox(width: 6),
                  Icon(CupertinoIcons.chevron_up_chevron_down, size: 12, color: context.secondary),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _menu(BuildContext context) => FocusScope(
        onKeyEvent: (node, event) {
          if (event is KeyUpEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.escape) {
            close();
          } else if (key == LogicalKeyboardKey.arrowDown) {
            node.nextFocus();
          } else if (key == LogicalKeyboardKey.arrowUp) {
            node.previousFocus();
          } else {
            return KeyEventResult.ignored;
          }
          return KeyEventResult.handled;
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: Listener(
                onPointerSignal: (_) => close(),
                child: GestureDetector(behavior: HitTestBehavior.opaque, onTapDown: (_) => close()),
              ),
            ),
            CompositedTransformFollower(
              link: anchor,
              targetAnchor: opensUp ? Alignment.topRight : Alignment.bottomRight,
              followerAnchor: opensUp ? Alignment.bottomRight : Alignment.topRight,
              offset: Offset(-6, opensUp ? -2 : 2),
              child: Align(
                alignment: opensUp ? Alignment.bottomRight : Alignment.topRight,
                child: _Grow(
                  alignment: opensUp ? Alignment.bottomRight : Alignment.topRight,
                  child: Container(
                    constraints: BoxConstraints(minWidth: 210, maxWidth: 400, maxHeight: room),
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: context.isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF7F7F8),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: context.line, width: 0.5),
                      boxShadow: const [BoxShadow(color: Color(0x4D000000), blurRadius: 24, offset: Offset(0, 10))],
                    ),
                    child: SingleChildScrollView(
                      child: IntrinsicWidth(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final entry in widget.options.entries)
                              _MenuItem(
                                text: entry.value,
                                checked: entry.key == widget.value,
                                onTap: () {
                                  close();
                                  if (entry.key != widget.value) widget.onChanged(entry.key);
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

/// Arrives from the corner nearest the row that opened it.
class _Grow extends StatefulWidget {
  const _Grow({required this.child, required this.alignment});
  final Widget child;
  final Alignment alignment;

  @override
  State<_Grow> createState() => _GrowState();
}

class _GrowState extends State<_Grow> {
  var shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => shown = true));
  }

  @override
  Widget build(BuildContext context) => Spring(
        value: shown ? 1 : 0,
        response: 0.24,
        child: widget.child,
        builder: (_, t, child) => Opacity(
          opacity: t.clamp(0, 1),
          child: Transform.scale(scale: 0.94 + 0.06 * t, alignment: widget.alignment, child: child),
        ),
      );
}

class _MenuItem extends StatefulWidget {
  const _MenuItem({required this.text, required this.checked, required this.onTap});
  final String text;
  final bool checked;
  final VoidCallback onTap;

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

/// Like a macOS menu, the pointer and the arrow keys move one shared highlight: hovering an item
/// focuses it. The current choice is focused when the menu opens.
class _MenuItemState extends State<_MenuItem> {
  final focus = FocusNode();
  var hovered = false;

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: widget.checked,
        label: widget.text,
        child: FocusableActionDetector(
          focusNode: focus,
          autofocus: widget.checked,
          mouseCursor: SystemMouseCursors.click,
          shortcuts: pressKeys,
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
          onFocusChange: (value) => setState(() => hovered = value),
          onShowHoverHighlight: (value) {
            if (value) focus.requestFocus();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              decoration: BoxDecoration(color: hovered ? accent : null, borderRadius: BorderRadius.circular(6)),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: hovered ? CupertinoColors.white : null),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 20, child: widget.checked ? Icon(CupertinoIcons.check_mark, size: 13, color: hovered ? CupertinoColors.white : null) : null),
                    Flexible(child: Text(widget.text, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
